import Foundation
import SwiftData

class CustomVocabularyService {
    static let shared = CustomVocabularyService()

    private init() {}

    func getCustomVocabulary(from context: ModelContext) -> String {
        guard let customWords = getCustomVocabularyWords(from: context), !customWords.isEmpty else {
            return ""
        }

        let wordsText = customWords.joined(separator: ", ")
        return "Important Vocabulary: \(wordsText)"
    }

    /// Vocabulary words, trimmed and without case-insensitive duplicates.
    func vocabularyTerms(from context: ModelContext) -> [String] {
        var seen = Set<String>()
        return (getCustomVocabularyWords(from: context) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    private func getCustomVocabularyWords(from context: ModelContext) -> [String]? {
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\VocabularyWord.word)])

        do {
            let items = try context.fetch(descriptor)
            let words = items.map { $0.word }
            return words.isEmpty ? nil : words
        } catch {
            return nil
        }
    }
}
