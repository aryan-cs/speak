import AppKit
import Foundation

/// Holds back replacements whose source is a single real word, like "print" -> "Qdrant", until
/// the user has made the same fix twice. A replacement rewrites that word in every later
/// dictation, so one correction is not enough evidence for an everyday word. The corrected
/// term is still added as vocabulary on the first fix.
@MainActor
enum AutoLearnEverydayWordGuard {
    private static let evidenceKey = "AutoLearnEverydayWordEvidence"
    private static let maximumEvidenceEntries = 200

    static func filter(_ decisions: [AutoLearnReviewDecision]) -> [AutoLearnReviewDecision] {
        var evidence = UserDefaults.standard.stringArray(forKey: evidenceKey) ?? []
        defer {
            UserDefaults.standard.set(Array(evidence.suffix(maximumEvidenceEntries)), forKey: evidenceKey)
        }

        return decisions.map { decision in
            guard decision.learningAction == .addReplacementAndVocabulary
                || decision.learningAction == .addReplacementOnly,
                let source = decision.incorrectTextToReplace,
                let term = decision.correctedVocabularyTerm,
                isEverydayWord(source)
            else {
                return decision
            }

            let key = "\(WordReplacementVariants.key(for: source))\u{1F}\(term)"
            if let index = evidence.firstIndex(of: key) {
                evidence.remove(at: index)
                return decision
            }

            evidence.append(key)
            return AutoLearnReviewDecision(
                candidateID: decision.candidateID,
                learningAction: decision.learningAction == .addReplacementAndVocabulary
                    ? .addVocabularyOnly
                    : .rejectCorrection,
                incorrectTextToReplace: decision.incorrectTextToReplace,
                correctedVocabularyTerm: decision.correctedVocabularyTerm
            )
        }
    }

    /// A single word the spell checker knows in the user's language or English. Phrases such
    /// as "super base" are left alone: replacing the whole phrase does not touch either word
    /// on its own.
    static func isEverydayWord(_ text: String) -> Bool {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty, word.allSatisfy(\.isLetter) else { return false }
        let checker = NSSpellChecker.shared
        // An explicit language: automatic detection accepts words from any language, so
        // misheard names like "Versal" would pass as real words.
        return spellingLanguages.contains { language in
            checker.checkSpelling(
                of: word,
                startingAt: 0,
                language: language,
                wrap: false,
                inSpellDocumentWithTag: 0,
                wordCount: nil
            ).location == NSNotFound
        }
    }

    private static var spellingLanguages: [String] {
        let available = Set(NSSpellChecker.shared.availableLanguages)
        let preferred = Locale.preferredLanguages.first.flatMap {
            Locale(identifier: $0).language.languageCode?.identifier
        }
        var languages: [String] = []
        for candidate in [preferred, "en"].compactMap({ $0 })
        where available.contains(candidate) && !languages.contains(candidate) {
            languages.append(candidate)
        }
        return languages
    }
}
