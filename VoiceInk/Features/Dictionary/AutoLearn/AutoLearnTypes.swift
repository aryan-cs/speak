import Foundation

enum AutoLearnTextNormalizer {
    /// Produces a comparison-only representation of text exposed by editable
    /// web controls. The original field value remains untouched for anchoring.
    static func accessibilityComparable(_ text: String) -> String {
        // Editors restyle pasted text: a blank line between paragraphs reads back as one
        // newline, spaces become non-breaking, and quotes turn smart or straight. Comparison
        // ignores all of that, so whitespace runs become one space and quotes are folded.
        let folded = text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .map { quoteFolding[$0] ?? $0 }
        return String(folded)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .precomposedStringWithCanonicalMapping
    }

    private static let quoteFolding: [Character: Character] = [
        "\u{2018}": "'", "\u{2019}": "'", "\u{201A}": "'", "\u{201B}": "'",
        "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"", "\u{201F}": "\"",
    ]
}

enum AutoLearnTextSimilarity {
    /// How much of `original` survives in `edited`, from 0 to 1. Short texts use edit distance;
    /// long ones the share of words kept, which stays cheap enough to check on every poll.
    static func ratio(_ original: String, _ edited: String) -> Double {
        let a = Array(original.lowercased()), b = Array(edited.lowercased())
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        guard a.count + b.count <= 400 else {
            let originalWords = original.lowercased().split(whereSeparator: \.isWhitespace)
            let editedWords = Set(edited.lowercased().split(whereSeparator: \.isWhitespace))
            guard !originalWords.isEmpty else { return 0 }
            return Double(originalWords.filter(editedWords.contains).count) / Double(originalWords.count)
        }
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }

    /// A correction keeps most of what was pasted. Below this, the text was replaced wholesale,
    /// such as a browser address bar showing its search URL after Return.
    static let minimumCorrectionRatio = 0.3

    static func isCorrection(of original: String, to edited: String) -> Bool {
        ratio(original, edited) >= minimumCorrectionRatio
    }
}

struct AutoLearnPasteToken: Hashable, Sendable {
    let id: UUID
}

enum AutoLearnCaptureOutcome: Sendable {
    case captured(AutoLearnPasteToken)
    /// The field may not show the paste yet; web editors update Accessibility late.
    /// `detail` describes the field for diagnosis without including any of its text.
    case retryable(reason: String, detail: String)
    case rejected(reason: String)
}

enum AutoLearnFieldObservation: Sendable {
    case unchanged
    case edited
    /// The pasted text is no longer in the field, e.g. a chat app sent and cleared it.
    case detached
    case unreadable
}

struct AutoLearnRevision: Sendable {
    let original: String
    let corrected: String
}

struct AutoLearnFieldSnapshot: Sendable {
    let baselineFieldText: String
    let finalFieldText: String
    let pastedRange: NSRange
    let originalPastedText: String
}

struct DetectedCorrectionCandidate: Hashable, Sendable {
    let originalText: String
    let correctedText: String
}

struct AutoLearnReviewCandidate: Sendable {
    let candidateID: UUID
    let originalText: String
    let correctedText: String
}

enum AutoLearnReviewAction: String, Codable, Sendable {
    case addReplacementAndVocabulary
    case addReplacementOnly
    case addVocabularyOnly
    case rejectCorrection
}

struct AutoLearnReviewDecision: Sendable {
    let candidateID: UUID
    let learningAction: AutoLearnReviewAction
    let incorrectTextToReplace: String?
    let correctedVocabularyTerm: String?
}

enum AutoLearnUnresolvedReason: String, Sendable {
    case missingDecision
    case conflictingDecisions
    case missingRequiredActionValues
    case invalidRequiredActionValues
}

struct AutoLearnUnresolvedReview: Sendable {
    let candidateID: UUID
    let reason: AutoLearnUnresolvedReason
    let learningAction: AutoLearnReviewAction?
    let incorrectTextToReplace: String?
    let correctedVocabularyTerm: String?
}

struct AutoLearnReviewResult: Sendable {
    let reviewDecisions: [AutoLearnReviewDecision]
    let unresolvedReviews: [AutoLearnUnresolvedReview]
}

struct AutoLearnReviewProposal: Codable, Identifiable, Sendable {
    let id: UUID
    let candidateID: UUID
    let originalText: String
    let correctedText: String
    let learningAction: AutoLearnReviewAction
    let incorrectTextToReplace: String?
    let correctedVocabularyTerm: String?

    var addsReplacement: Bool {
        learningAction == .addReplacementAndVocabulary || learningAction == .addReplacementOnly
    }

    var addsVocabulary: Bool {
        learningAction == .addReplacementAndVocabulary || learningAction == .addVocabularyOnly
    }

    var reviewCandidate: AutoLearnReviewCandidate {
        AutoLearnReviewCandidate(
            candidateID: candidateID,
            originalText: originalText,
            correctedText: correctedText
        )
    }

    var reviewDecision: AutoLearnReviewDecision {
        AutoLearnReviewDecision(
            candidateID: candidateID,
            learningAction: learningAction,
            incorrectTextToReplace: incorrectTextToReplace,
            correctedVocabularyTerm: correctedVocabularyTerm
        )
    }
}

struct AutoLearnReviewSelection: Sendable {
    let proposalID: UUID
    let includesReplacement: Bool
    let includesVocabulary: Bool
    let incorrectTextToReplace: String?
    let correctedVocabularyTerm: String
}

struct AutoLearnMutationSummary: Sendable {
    let createdCount: Int
    let updatedCount: Int
    let vocabularyCount: Int
    let learnedCorrections: [AutoLearnAppliedCorrection]

    var hasChanges: Bool {
        createdCount > 0 || updatedCount > 0 || vocabularyCount > 0
    }

    static let empty = AutoLearnMutationSummary(
        createdCount: 0,
        updatedCount: 0,
        vocabularyCount: 0,
        learnedCorrections: []
    )
}

struct AutoLearnAppliedCorrection: Sendable {
    let incorrectTextToReplace: String
    let correctedVocabularyTerm: String
    let replacementSourceWasAdded: Bool
    let vocabularyCreationDate: Date?
}

enum AutoLearnReviewSchedule: String, CaseIterable, Identifiable {
    case immediately
    case manually

    var id: String { rawValue }

    var title: String {
        switch self {
        case .immediately: String(localized: "Immediately")
        case .manually: String(localized: "Manually")
        }
    }

}

enum AutoLearnLimits {
    static let observationDurationNanoseconds: UInt64 = 60_000_000_000
    static let verificationDelayNanoseconds: UInt64 = 120_000_000
    /// Further waits before re-reading a field that does not show the paste yet (~2.3 s total).
    static let captureRetryDelaysNanoseconds: [UInt64] = [200_000_000, 350_000_000, 600_000_000, 1_000_000_000]
    static let fieldObservationIntervalNanoseconds: UInt64 = 250_000_000
    static let reviewTimeoutSeconds: TimeInterval = 60
    static let focusChangeGraceNanoseconds: UInt64 = 250_000_000
    static let accessibilityTimeoutSeconds: Float = 0.20
    static let captureAccessibilityTimeoutSeconds: Float = 0.10
    static let maximumFieldUTF16Length = 100_000
    static let maximumPastedCharacters = 12_000
    static let maximumDiffSegments = 2_048
    static let maximumCandidateCharacters = 256
    static let maximumCandidateSegments = 24
    static let reviewContextSegmentsPerSide = 3
    static let maximumUnspacedCandidateCharacters = 32
    static let maximumReviewBatchCandidates = 100
    /// A small local model takes about a minute for 20 candidates, past the review timeout.
    static let localReviewBatchCandidates = 6

    static var reviewBatchCandidates: Int {
        AutoLearnSettings.selectedProvider == .ollama ? localReviewBatchCandidates : maximumReviewBatchCandidates
    }
}

enum AutoLearnProviderPolicy {
    static func isSupported(_ provider: AIProvider) -> Bool {
        provider.supportsEnhancement
            && provider != .voiceInkRefine
    }
}
