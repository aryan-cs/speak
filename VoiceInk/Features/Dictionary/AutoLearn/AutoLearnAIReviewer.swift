import Foundation
import OSLog

@MainActor
final class AutoLearnAIReviewer: @unchecked Sendable {
    private struct AutoLearnReviewRequest: Encodable {
        struct CandidateForReview: Encodable {
            let candidateID: Int
            let originalText: String
            let correctedText: String
        }

        let candidatesForReview: [CandidateForReview]
    }

    private struct CandidateReviewDecision: Decodable {
        let candidateID: Int
        let learningAction: AutoLearnReviewAction
        let incorrectTextToReplace: String?
        let correctedVocabularyTerm: String?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case candidateID
            case reason
            case learningAction
            case incorrectTextToReplace
            case correctedVocabularyTerm
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let returnedKeys = Set(container.allKeys.map(\.stringValue))
            // `reason` is optional scratch space that lets small models decide more reliably; it is ignored.
            let requiredKeys = Set(CodingKeys.allCases.map(\.stringValue)).subtracting([CodingKeys.reason.stringValue])
            guard requiredKeys.isSubset(of: returnedKeys) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .candidateID,
                    in: container,
                    debugDescription: "Each decision must contain the four required fields."
                )
            }

            candidateID = try container.decode(Int.self, forKey: .candidateID)
            learningAction = try container.decode(AutoLearnReviewAction.self, forKey: .learningAction)
            incorrectTextToReplace = try container.decodeIfPresent(
                String.self,
                forKey: .incorrectTextToReplace
            )
            correctedVocabularyTerm = try container.decodeIfPresent(
                String.self,
                forKey: .correctedVocabularyTerm
            )
        }
    }

    private enum ReviewError: LocalizedError {
        case unavailable
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return String(
                    localized: "The configured AI enhancement provider cannot review Auto Learn candidates."
                )
            case .invalidResponse:
                return String(localized: "The AI returned an invalid Auto Learn review response.")
            }
        }
    }

    private let enhancementService: AIEnhancementService
    private let logger = Logger(
        subsystem: AppConstants.logSubsystem,
        category: "AutoLearnAIReview"
    )

    init(enhancementService: AIEnhancementService) {
        self.enhancementService = enhancementService
    }

    /// True when a review could run right now. Used to defer queued reviews
    /// while providers are still starting up instead of recording a failure.
    var hasAvailableProvider: Bool {
        guard let aiService = enhancementService.getAIService() else { return false }
        let connectedProviders = availableProviders(in: aiService)
        if let selected = AutoLearnSettings.selectedProvider {
            return connectedProviders.contains(selected)
        }
        return !connectedProviders.isEmpty
    }

    func review(_ candidates: [AutoLearnReviewCandidate]) async throws -> AutoLearnReviewResult {
        guard !candidates.isEmpty else {
            return AutoLearnReviewResult(reviewDecisions: [], unresolvedReviews: [])
        }
        guard let aiService = enhancementService.getAIService() else {
            throw ReviewError.unavailable
        }

        let connectedProviders = availableProviders(in: aiService)
        // Respect the user's provider choice. Ollama keeps correction review on-device.
        guard let provider = AutoLearnSettings.selectedProvider ?? connectedProviders.first,
            connectedProviders.contains(provider)
        else {
            throw ReviewError.unavailable
        }
        let modelName = AutoLearnSettings.selectedModel ?? aiService.selectedModel(for: provider)

        let candidatesForReview = candidates.enumerated().map { index, candidate in
            AutoLearnReviewRequest.CandidateForReview(
                candidateID: index,
                originalText: candidate.originalText,
                correctedText: candidate.correctedText
            )
        }
        let requestData = try JSONEncoder().encode(
            AutoLearnReviewRequest(candidatesForReview: candidatesForReview)
        )
        let requestText = String(decoding: requestData, as: UTF8.self)

        let loggedModelName = modelName ?? "provider-default"
        logger.notice(
            "Auto Learn review started provider=\(provider.rawValue, privacy: .public) model=\(loggedModelName, privacy: .public) candidates=\(candidates.count, privacy: .public)"
        )
        let responseText = try await aiService.reviewAutoLearnCandidates(
            payload: requestText,
            systemPrompt: Self.reviewPrompt,
            provider: provider,
            modelName: modelName
        )
        let candidateReviewDecisions = try decodeResponse(
            responseText,
            provider: provider,
            modelName: loggedModelName
        )
        let expectedCandidateIDs = Set(candidates.indices)
        let decisionsByCandidateID = Dictionary(grouping: candidateReviewDecisions) {
            $0.candidateID
        }
        let correctedContexts = candidates.map(\.correctedText)
        for unknownCandidateID in decisionsByCandidateID.keys
        where !expectedCandidateIDs.contains(unknownCandidateID) {
            logger.warning(
                "Ignoring Auto Learn decision with unknown candidate ID=\(unknownCandidateID, privacy: .public)"
            )
        }

        var reviewDecisions: [AutoLearnReviewDecision] = []
        var unresolvedReviews: [AutoLearnUnresolvedReview] = []

        for (index, candidate) in candidates.enumerated() {
            guard let matchingDecisions = decisionsByCandidateID[index] else {
                unresolvedReviews.append(
                    unresolvedReview(for: candidate, reason: .missingDecision)
                )
                continue
            }

            // One diff candidate can contain adjacent corrections with no
            // unchanged token between them. Let the reviewer separate those
            // terms, but never mix an accepted correction with a rejection.
            if matchingDecisions.count > 1,
                matchingDecisions.contains(where: { $0.learningAction == .rejectCorrection })
            {
                unresolvedReviews.append(
                    unresolvedReview(
                        for: candidate,
                        reason: .conflictingDecisions,
                        decision: matchingDecisions.first
                    )
                )
                continue
            }

            var validatedDecisions: [AutoLearnReviewDecision] = []
            var unresolvedDecision: AutoLearnUnresolvedReview?
            for decision in matchingDecisions {
                let validation = validate(
                    decision,
                    for: candidate,
                    correctedContexts: correctedContexts
                )
                guard let validatedDecision = validation.decision else {
                    unresolvedDecision = unresolvedReview(
                        for: candidate,
                        reason: validation.failure ?? .invalidRequiredActionValues,
                        decision: decision
                    )
                    break
                }
                validatedDecisions.append(validatedDecision)
            }

            if let unresolvedDecision {
                unresolvedReviews.append(unresolvedDecision)
            } else if !decisionsAreIndependent(validatedDecisions, for: candidate) {
                unresolvedReviews.append(
                    unresolvedReview(
                        for: candidate,
                        reason: .conflictingDecisions,
                        decision: matchingDecisions.first
                    )
                )
            } else {
                reviewDecisions.append(contentsOf: validatedDecisions)
            }
        }

        return AutoLearnReviewResult(
            reviewDecisions: reviewDecisions,
            unresolvedReviews: unresolvedReviews
        )
    }

    private func availableProviders(in aiService: AIService) -> [AIProvider] {
        aiService.connectedProviders.filter {
            AutoLearnProviderPolicy.isSupported($0)
                && ($0 != .ollama || !aiService.availableModels(for: $0).isEmpty)
        }
    }

    private func unresolvedReview(
        for candidate: AutoLearnReviewCandidate,
        reason: AutoLearnUnresolvedReason,
        decision: CandidateReviewDecision? = nil
    ) -> AutoLearnUnresolvedReview {
        AutoLearnUnresolvedReview(
            candidateID: candidate.candidateID,
            reason: reason,
            learningAction: decision?.learningAction,
            incorrectTextToReplace: decision?.incorrectTextToReplace,
            correctedVocabularyTerm: decision?.correctedVocabularyTerm
        )
    }

    private func validate(
        _ decision: CandidateReviewDecision,
        for candidate: AutoLearnReviewCandidate,
        correctedContexts: [String]
    ) -> (decision: AutoLearnReviewDecision?, failure: AutoLearnUnresolvedReason?) {
        if decision.learningAction == .rejectCorrection {
            return (
                AutoLearnReviewDecision(
                    candidateID: candidate.candidateID,
                    learningAction: .rejectCorrection,
                    incorrectTextToReplace: nil,
                    correctedVocabularyTerm: nil
                ),
                nil
            )
        }

        guard let proposedVocabularyTerm = decision.correctedVocabularyTerm?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return (nil, .missingRequiredActionValues)
        }
        let repairedSpans = CorrectionDiffEngine.repairedReviewSpans(
            incorrectText: decision.incorrectTextToReplace?.trimmingCharacters(in: .whitespacesAndNewlines),
            correctedTerm: proposedVocabularyTerm,
            originalText: candidate.originalText,
            correctedText: candidate.correctedText
        )
        let correctedVocabularyTerm = repairedSpans.correctedTerm
        guard !correctedVocabularyTerm.isEmpty,
            correctedVocabularyTerm.count <= AutoLearnLimits.maximumCandidateCharacters,
            isGrounded(correctedVocabularyTerm, in: correctedContexts)
        else {
            return (nil, .invalidRequiredActionValues)
        }

        if decision.learningAction == .addVocabularyOnly {
            return (
                AutoLearnReviewDecision(
                    candidateID: candidate.candidateID,
                    learningAction: .addVocabularyOnly,
                    incorrectTextToReplace: nil,
                    correctedVocabularyTerm: correctedVocabularyTerm
                ),
                nil
            )
        }

        guard let incorrectTextToReplace = repairedSpans.incorrectText else {
            return (nil, .missingRequiredActionValues)
        }
        guard !incorrectTextToReplace.isEmpty,
            incorrectTextToReplace != correctedVocabularyTerm,
            incorrectTextToReplace.count <= AutoLearnLimits.maximumCandidateCharacters,
            !incorrectTextToReplace.contains(","),
            isExactSubstring(incorrectTextToReplace, of: candidate.originalText)
        else {
            return (nil, .invalidRequiredActionValues)
        }

        if differsOnlyByLetterCase(incorrectTextToReplace, correctedVocabularyTerm) {
            return (
                AutoLearnReviewDecision(
                    candidateID: candidate.candidateID,
                    learningAction: .rejectCorrection,
                    incorrectTextToReplace: nil,
                    correctedVocabularyTerm: nil
                ),
                nil
            )
        }

        return (
            AutoLearnReviewDecision(
                candidateID: candidate.candidateID,
                learningAction: decision.learningAction,
                incorrectTextToReplace: incorrectTextToReplace,
                correctedVocabularyTerm: correctedVocabularyTerm
            ),
            nil
        )
    }

    private func differsOnlyByLetterCase(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: .caseInsensitive) == .orderedSame
    }

    private func isExactSubstring(_ term: String, of context: String) -> Bool {
        context.range(of: term, options: .literal) != nil
    }

    private func isGrounded(_ term: String, in contexts: [String]) -> Bool {
        contexts.contains { isExactSubstring(term, of: $0) }
    }

    private func decisionsAreIndependent(
        _ decisions: [AutoLearnReviewDecision],
        for candidate: AutoLearnReviewCandidate
    ) -> Bool {
        let originalTerms = decisions.compactMap(\.incorrectTextToReplace)
        guard canLocateWithoutOverlap(originalTerms, in: candidate.originalText) else {
            return false
        }

        // Batch canonicalization may intentionally return a corrected term
        // from another candidate, so only test terms present in this snippet.
        let localCorrectedTerms = decisions.compactMap(\.correctedVocabularyTerm).filter {
            isExactSubstring($0, of: candidate.correctedText)
        }
        return canLocateWithoutOverlap(localCorrectedTerms, in: candidate.correctedText)
    }

    private func canLocateWithoutOverlap(_ terms: [String], in text: String) -> Bool {
        guard terms.count > 1 else { return true }
        let text = text as NSString
        let rangesByTerm = terms.map { term -> [NSRange] in
            var matches: [NSRange] = []
            var searchRange = NSRange(location: 0, length: text.length)
            while searchRange.length > 0 {
                let match = text.range(of: term, options: .literal, range: searchRange)
                guard match.location != NSNotFound else { break }
                matches.append(match)
                let nextLocation = match.location + 1
                guard nextLocation < text.length else { break }
                searchRange = NSRange(
                    location: nextLocation,
                    length: text.length - nextLocation
                )
            }
            return matches
        }

        func assign(_ termIndex: Int, occupied: [NSRange]) -> Bool {
            guard termIndex < rangesByTerm.count else { return true }
            for range in rangesByTerm[termIndex]
            where occupied.allSatisfy({ NSIntersectionRange($0, range).length == 0 }) {
                if assign(termIndex + 1, occupied: occupied + [range]) {
                    return true
                }
            }
            return false
        }

        return assign(0, occupied: [])
    }

    private func decodeResponse(
        _ text: String,
        provider: AIProvider,
        modelName: String
    ) throws -> [CandidateReviewDecision] {
        let payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Local models sometimes wrap the array in a code fence or leave stray characters around it.
        let data = Data((Self.firstJSONArray(in: payload) ?? payload).utf8)

        do {
            return try JSONDecoder().decode([CandidateReviewDecision].self, from: data)
        } catch {
            let diagnostic = invalidResponseDiagnostic(for: data)
            logInvalidResponse(
                payload,
                provider: provider,
                modelName: modelName,
                reason: diagnostic.reason,
                shape: diagnostic.shape
            )
            throw ReviewError.invalidResponse
        }
    }

    /// The first balanced top-level JSON array in `text`, ignoring brackets inside strings.
    nonisolated static func firstJSONArray(in text: String) -> String? {
        guard let start = text.firstIndex(of: "[") else { return nil }
        var depth = 0
        var isInString = false
        var isEscaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
            } else if character == "\"" {
                isInString = true
            } else if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private func logInvalidResponse(
        _ payload: String,
        provider: AIProvider,
        modelName: String,
        reason: String,
        shape: String = "unknown"
    ) {
        let preview = String(payload.prefix(1_000))
        logger.error(
            "Auto Learn response invalid provider=\(provider.rawValue, privacy: .public) model=\(modelName, privacy: .public) reason=\(reason, privacy: .public) shape=\(shape, privacy: .public) characters=\(payload.count, privacy: .public) responsePreview=\(preview, privacy: .private)"
        )
    }

    private func invalidResponseDiagnostic(for data: Data) -> (reason: String, shape: String) {
        guard let value = try? JSONSerialization.jsonObject(with: data) else {
            return ("malformed-json", "invalid-json")
        }
        if value is [Any] { return ("invalid-decision-array", "array") }
        if value is [String: Any] { return ("expected-top-level-array", "object") }
        return ("unsupported-json-shape", "scalar")
    }

    // Tuned for small local models: learns misheard names, products, and terms (including
    // well-known ones), rejects ordinary edits, and asks for a short reason before each decision.
    private static let reviewPrompt = """
        You review corrections a user made to text produced by speech-to-text dictation. Decide which corrections should be remembered so future dictation gets them right.

        Each candidate has:
        - originalText: what speech-to-text produced, with a few words of surrounding context.
        - correctedText: the same passage after the user's edit.

        Learn a correction only when both hold:
        1. The changed words in originalText are a mis-hearing of the new words: they sound alike when spoken aloud.
        2. The new words are a proper noun or specialized term: a person's name, product, brand, company, project, app, command, or technical term. Well-known names count.
        The mis-heard words are often ordinary English words that happen to sound like the name (for example "mail chimp" for "Mailchimp"). Brands often use unusual spellings of ordinary words (Lyft, Flickr); replacing the dictionary spelling with the brand's spelling is a name to learn, not a spelling fix.

        Reject (learningAction "rejectCorrection") when the edit:
        - only changes capitalization, spacing, or punctuation;
        - fixes the spelling or grammar of an ordinary word, where both versions are the same ordinary word (for example "recieve" to "receive");
        - changes meaning: different words, synonyms, dates, numbers, or facts;
        - rewrites or rephrases the sentence;
        - or you are unsure.

        For a learned correction choose:
        - "addReplacementAndVocabulary": the usual choice for names, products, and terms.
        - "addReplacementOnly": only a first name or only a surname is visible, not the person's full name.
        - "addVocabularyOnly": the term is right, but the mis-heard words are ordinary enough that replacing them everywhere would be unsafe.

        Fields:
        - incorrectTextToReplace: only the mis-heard words, copied exactly from originalText, keeping their original spelling and capitalization (not the surrounding context and never the corrected spelling). null for addVocabularyOnly and rejectCorrection.
        - correctedVocabularyTerm: only the corrected term, copied exactly from correctedText. null for rejectCorrection.
        Keep multi-word names whole, including unchanged parts.

        Return only a JSON array with one object per candidateID. Each object has exactly these fields, in this order: candidateID, reason, learningAction, incorrectTextToReplace, correctedVocabularyTerm. reason is one short sentence saying what changed and why it is or is not a name or term to learn; write it before deciding. No other text and no Markdown.

        Example input:
        {"candidatesForReview":[{"candidateID":0,"originalText":"we can deploy it on versel after","correctedText":"we can deploy it on Vercel after"},{"candidateID":1,"originalText":"the data lives in super base now","correctedText":"the data lives in Supabase now"},{"candidateID":2,"originalText":"see you at 3 pm","correctedText":"see you at 4 pm"},{"candidateID":3,"originalText":"thanks for the help","correctedText":"Thanks for the help!"},{"candidateID":4,"originalText":"launch the mail chimp campaign","correctedText":"launch the Mailchimp campaign"},{"candidateID":5,"originalText":"please ask jon smyth for the","correctedText":"please ask Jon Smith for the"}]}
        Example output:
        [{"candidateID":0,"reason":"'versel' sounds like the platform name 'Vercel'.","learningAction":"addReplacementAndVocabulary","incorrectTextToReplace":"versel","correctedVocabularyTerm":"Vercel"},{"candidateID":1,"reason":"'super base' sounds like the product name 'Supabase'.","learningAction":"addReplacementAndVocabulary","incorrectTextToReplace":"super base","correctedVocabularyTerm":"Supabase"},{"candidateID":2,"reason":"A time change alters the meaning.","learningAction":"rejectCorrection","incorrectTextToReplace":null,"correctedVocabularyTerm":null},{"candidateID":3,"reason":"Only capitalization and punctuation changed.","learningAction":"rejectCorrection","incorrectTextToReplace":null,"correctedVocabularyTerm":null},{"candidateID":4,"reason":"'mail chimp' sounds like the product name 'Mailchimp'.","learningAction":"addReplacementAndVocabulary","incorrectTextToReplace":"mail chimp","correctedVocabularyTerm":"Mailchimp"},{"candidateID":5,"reason":"'jon smyth' sounds like the full name 'Jon Smith'.","learningAction":"addReplacementAndVocabulary","incorrectTextToReplace":"jon smyth","correctedVocabularyTerm":"Jon Smith"}]
        """
}
