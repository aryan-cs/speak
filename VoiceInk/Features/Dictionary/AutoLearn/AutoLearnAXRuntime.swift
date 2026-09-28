import ApplicationServices
import Foundation

final class AutoLearnAXRuntime: @unchecked Sendable {
    private struct Session {
        let token: AutoLearnPasteToken
        let appElement: AXUIElement
        let targetElement: AXUIElement
        let baselineFieldText: String
        let pastedRange: NSRange
        let pastedText: String
        /// The latest field text that still contains an edited version of the paste. Chat apps
        /// clear the field on send, so this is what the user's corrections looked like.
        var lastEditedFieldText: String?
    }

    private let queue = DispatchQueue(label: AppConstants.logSubsystem + ".auto-learn.accessibility")
    private let textReader = AutoLearnAXTextReader()
    private var session: Session?

    func capturePastedText(text: String, processID: pid_t) async -> AutoLearnCaptureOutcome {
        await perform { [self] in
            session = nil

            guard AXIsProcessTrusted() else { return .rejected(reason: "accessibility-not-trusted") }
            guard processID != ProcessInfo.processInfo.processIdentifier else {
                return .rejected(reason: "target-is-speak")
            }
            guard !text.isEmpty else { return .rejected(reason: "empty-pasted-text") }
            guard text.count <= AutoLearnLimits.maximumPastedCharacters else {
                return .rejected(reason: "pasted-text-too-large")
            }

            var matchedReading: AutoLearnAXTextReading?
            var pastedRange: NSRange?
            var lastReading: AutoLearnAXTextReading?

            let readings = textReader.focusedReadings(processID: processID)
            for reading in readings {
                lastReading = reading
                if let resolvedRange = resolvedPastedRange(
                    for: text,
                    selectionAfterPaste: reading.selection,
                    fieldText: reading.fieldText
                ) {
                    matchedReading = reading
                    pastedRange = resolvedRange
                    break
                }
            }

            // Web accessibility stays enabled so a retry does not wait for the page's
            // accessibility tree to be rebuilt; `abandonCapture` restores it.
            guard let reading = matchedReading, let pastedRange else {
                return .retryable(
                    reason: lastReading == nil ? "focused-text-reading-unavailable" : "pasted-range-invalid",
                    detail: lastReading.map { captureDiagnostics(for: text, reading: $0) } ?? "readings=0"
                )
            }

            let fieldText = reading.fieldText
            let observedPastedText = (fieldText as NSString).substring(with: pastedRange)

            AXUIElementSetMessagingTimeout(
                reading.appElement,
                AutoLearnLimits.accessibilityTimeoutSeconds
            )
            let token = AutoLearnPasteToken(id: UUID())
            session = Session(
                token: token,
                appElement: reading.appElement,
                targetElement: reading.targetElement,
                baselineFieldText: fieldText,
                pastedRange: pastedRange,
                pastedText: observedPastedText
            )
            return .captured(token)
        }
    }

    /// Sizes and flags only, never field or pasted text, so logs stay private.
    private func captureDiagnostics(for pastedText: String, reading: AutoLearnAXTextReading) -> String {
        let core = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedField = AutoLearnTextNormalizer.accessibilityComparable(reading.fieldText)
        let normalizedCore = AutoLearnTextNormalizer.accessibilityComparable(core)
        let selection = reading.selection.map { "\($0.location),\($0.length)" } ?? "none"
        return [
            "fieldUTF16=\(reading.fieldText.utf16.count)",
            "pastedUTF16=\(pastedText.utf16.count)",
            "selection=\(selection)",
            "containsExact=\(reading.fieldText.contains(core))",
            "containsNormalized=\(!normalizedCore.isEmpty && normalizedField.contains(normalizedCore))",
            "source=\(reading.source)",
            "focus=\(reading.focusSource)",
        ].joined(separator: " ")
    }

    /// Restores web accessibility after every capture attempt for a paste has failed.
    func abandonCapture(processID: pid_t) async {
        await perform { [self] in
            guard session == nil else { return }
            textReader.restoreWebAccessibility(
                processID: processID,
                appElement: AXUIElementCreateApplication(processID)
            )
        }
    }

    /// Reads the field once during observation and remembers the latest edited version of the
    /// paste, so the corrections survive a chat app clearing the field when the message is sent.
    func observeField(token: AutoLearnPasteToken) async -> AutoLearnFieldObservation? {
        await perform { [self] in
            guard var active = session, active.token == token else { return nil }
            guard let value = textReader.textValue(from: active.targetElement),
                value.text.utf16.count <= AutoLearnLimits.maximumFieldUTF16Length
            else {
                return .unreadable
            }

            switch pastedTextState(in: value.text, for: active) {
            case .missing:
                return .detached
            case .unchanged:
                // An edit that was undone no longer counts.
                active.lastEditedFieldText = nil
                session = active
                return .unchanged
            case .edited:
                active.lastEditedFieldText = value.text
                session = active
                return .edited
            }
        }
    }

    /// Ends the session and returns the field as the user left it. The live field wins while it
    /// still contains the paste; otherwise the last observed edit is used. `preferObservedEdits`
    /// skips the live read, for when a newer paste may already be in the field.
    func finishSnapshot(
        token: AutoLearnPasteToken,
        preferObservedEdits: Bool = false
    ) async -> AutoLearnFieldSnapshot? {
        await perform { [self] in
            guard let active = session, active.token == token else { return nil }
            session = nil

            defer { textReader.restoreWebAccessibility(processID: AXProcessID(active.appElement), appElement: active.appElement) }

            var finalFieldText = active.lastEditedFieldText
            if !preferObservedEdits,
                let liveText = textReader.textValue(from: active.targetElement)?.text,
                liveText.utf16.count <= AutoLearnLimits.maximumFieldUTF16Length,
                pastedTextState(in: liveText, for: active) != .missing
            {
                finalFieldText = liveText
            }

            guard let finalFieldText,
                !textIsExactlyEqual(finalFieldText, active.baselineFieldText)
            else { return nil }

            return AutoLearnFieldSnapshot(
                baselineFieldText: active.baselineFieldText,
                finalFieldText: finalFieldText,
                pastedRange: active.pastedRange,
                originalPastedText: active.pastedText
            )
        }
    }

    private enum PastedTextState {
        case unchanged
        case edited
        case missing
    }

    private func pastedTextState(in fieldText: String, for active: Session) -> PastedTextState {
        let snapshot = AutoLearnFieldSnapshot(
            baselineFieldText: active.baselineFieldText,
            finalFieldText: fieldText,
            pastedRange: active.pastedRange,
            originalPastedText: active.pastedText
        )
        guard let current = FinalSnapshotDiffEngine.currentPastedText(in: snapshot) else {
            return .missing
        }
        let normalizedCurrent = AutoLearnTextNormalizer.accessibilityComparable(current)
        // A cleared field still matches an empty span between the surrounding text.
        guard !normalizedCurrent.isEmpty else { return .missing }
        let normalizedOriginal = AutoLearnTextNormalizer.accessibilityComparable(active.pastedText)
        return textIsExactlyEqual(normalizedCurrent, normalizedOriginal) ? .unchanged : .edited
    }

    func targetIsFocused(token: AutoLearnPasteToken) async -> Bool {
        await perform { [self] in
            guard let active = session, active.token == token else { return false }
            return focusedElementMatches(active.targetElement, in: active.appElement)
        }
    }

    func discard(token: AutoLearnPasteToken? = nil) async {
        await perform { [self] in
            guard token == nil || session?.token == token else { return }
            if let active = session {
                textReader.restoreWebAccessibility(processID: AXProcessID(active.appElement), appElement: active.appElement)
            }
            session = nil
        }
    }

    private func AXProcessID(_ element: AXUIElement) -> pid_t {
        var pid: pid_t = 0
        _ = AXUIElementGetPid(element, &pid)
        return pid
    }

    private func textIsExactlyEqual(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }

    private func focusedElementMatches(_ targetElement: AXUIElement, in appElement: AXUIElement) -> Bool {
        guard copyBoolAttribute(kAXFrontmostAttribute, from: appElement) != false else {
            return false
        }

        if let appFocusedElement = copyAXElementAttribute(
            kAXFocusedUIElementAttribute,
            from: appElement
        ), CFEqual(appFocusedElement, targetElement) {
            return true
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        if let systemFocusedElement = copyAXElementAttribute(
            kAXFocusedUIElementAttribute,
            from: systemWideElement
        ), CFEqual(systemFocusedElement, targetElement) {
            return true
        }

        return copyBoolAttribute(kAXFocusedAttribute, from: targetElement) == true
    }

    private func copyAXElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func copyBoolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return (value as? NSNumber)?.boolValue
    }

    private func pastedRange(
        for pastedText: String,
        selectionAfterPaste: NSRange,
        fieldUTF16Length: Int
    ) -> NSRange? {
        guard isValid(selectionAfterPaste, inUTF16Length: fieldUTF16Length) else { return nil }

        let pastedLength = pastedText.utf16.count
        if selectionAfterPaste.length == pastedLength {
            return selectionAfterPaste
        }

        guard selectionAfterPaste.length == 0,
            selectionAfterPaste.location >= pastedLength
        else {
            return nil
        }

        return NSRange(
            location: selectionAfterPaste.location - pastedLength,
            length: pastedLength
        )
    }

    private func resolvedPastedRange(
        for pastedText: String,
        selectionAfterPaste: NSRange?,
        fieldText: String
    ) -> NSRange? {
        let field = fieldText as NSString
        let normalizedPastedText = AutoLearnTextNormalizer.accessibilityComparable(pastedText)

        if let selectionAfterPaste {
            if let inferredRange = pastedRange(
                for: pastedText,
                selectionAfterPaste: selectionAfterPaste,
                fieldUTF16Length: field.length
            ) {
                let observedText = field.substring(with: inferredRange)
                if textIsExactlyEqual(observedText, pastedText) {
                    return inferredRange
                }
                if !normalizedPastedText.isEmpty,
                    AutoLearnTextNormalizer.accessibilityComparable(observedText)
                        == normalizedPastedText
                {
                    return inferredRange
                }
            }
        }

        let exactMatches = exactMatches(for: pastedText, in: fieldText)
        if exactMatches.count == 1 {
            return exactMatches[0]
        }

        guard let selectionAfterPaste else {
            if let boundaryMatch = uniqueBoundaryWhitespaceMatch(
                for: pastedText,
                in: fieldText
            ) {
                return boundaryMatch
            }
            return nil
        }

        if let exactMatch = nearestMatch(
            in: exactMatches,
            near: selectionAfterPaste.location,
            pastedLength: pastedText.utf16.count
        ) {
            return exactMatch
        }

        guard selectionAfterPaste.length == 0 else { return nil }

        let expectedLength = pastedText.utf16.count
        let maximumLengthAdjustment = min(max(expectedLength / 4, 8), 128)
        guard !normalizedPastedText.isEmpty else { return nil }
        let caretLocation = min(max(selectionAfterPaste.location, 0), field.length)

        // Browser editors can expose the caret immediately before their own
        // trailing whitespace. Search only the closest boundaries around it.
        for endOffset in symmetricOffsets(upTo: 8) {
            let candidateEnd = caretLocation + endOffset
            guard candidateEnd >= 0, candidateEnd <= field.length else { continue }

            for lengthOffset in symmetricOffsets(upTo: maximumLengthAdjustment) {
                let candidateLength = expectedLength + lengthOffset
                guard candidateLength >= 0, candidateLength <= candidateEnd else { continue }

                let candidateRange = NSRange(
                    location: candidateEnd - candidateLength,
                    length: candidateLength
                )
                let candidateText = field.substring(with: candidateRange)
                if AutoLearnTextNormalizer.accessibilityComparable(candidateText)
                    == normalizedPastedText
                {
                    return candidateRange
                }
            }
        }

        return nil
    }

    /// Web editors may turn pasted boundary whitespace into their own leading
    /// space or trailing newline. Match the unchanged core exactly and leave
    /// the editor-owned whitespace outside the observed pasted range.
    private func uniqueBoundaryWhitespaceMatch(
        for pastedText: String,
        in fieldText: String
    ) -> NSRange? {
        let coreText = pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !coreText.isEmpty, !textIsExactlyEqual(coreText, pastedText) else {
            return nil
        }

        let matches = exactMatches(for: coreText, in: fieldText)
        return matches.count == 1 ? matches[0] : nil
    }

    private func symmetricOffsets(upTo maximum: Int) -> [Int] {
        guard maximum > 0 else { return [0] }
        var offsets = [0]
        offsets.reserveCapacity(maximum * 2 + 1)
        for offset in 1...maximum {
            offsets.append(offset)
            offsets.append(-offset)
        }
        return offsets
    }

    private func exactMatches(for pastedText: String, in fieldText: String) -> [NSRange] {
        let field = fieldText as NSString
        var searchRange = NSRange(location: 0, length: field.length)
        var matches: [NSRange] = []

        while searchRange.length > 0 {
            let match = field.range(of: pastedText, options: [], range: searchRange)
            guard match.location != NSNotFound else { break }
            matches.append(match)

            // Advance by one UTF-16 unit so overlapping occurrences are not skipped.
            let nextLocation = match.location + 1
            guard nextLocation < field.length else { break }
            searchRange = NSRange(location: nextLocation, length: field.length - nextLocation)
        }

        return matches
    }

    private func nearestMatch(
        in matches: [NSRange],
        near location: Int,
        pastedLength: Int
    ) -> NSRange? {
        let maximumDistance = max(pastedLength, 128)
        return matches.min {
            abs(NSMaxRange($0) - location) < abs(NSMaxRange($1) - location)
        }.flatMap {
            abs(NSMaxRange($0) - location) <= maximumDistance ? $0 : nil
        }
    }

    private func isValid(_ range: NSRange, inUTF16Length length: Int) -> Bool {
        range.location != NSNotFound
            && range.location >= 0
            && range.length >= 0
            && range.location <= length
            && range.length <= length - range.location
    }

    private func perform<T>(_ operation: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: operation())
            }
        }
    }
}
