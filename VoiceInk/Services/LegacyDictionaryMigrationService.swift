import Foundation
import SwiftData
import OSLog

/// Brings vocabulary and word replacements over from the store the app used
/// before its identity changed to `AppConstants.bundleIdentifier`. Without this,
/// the new Application Support directory starts empty and the old entries vanish.
@MainActor
final class LegacyDictionaryMigrationService {
    static let shared = LegacyDictionaryMigrationService()

    private let logger = Logger(subsystem: AppConstants.logSubsystem, category: "LegacyDictionaryMigrationService")
    private let completionKey = "HasCompletedLegacyDictionaryMigration"

    private struct LegacyWord {
        let word: String
        let dateAdded: Date
    }

    private struct LegacyReplacement {
        let originalText: String
        let replacementText: String
        let dateAdded: Date
        let isEnabled: Bool
    }

    private init() {}

    func runIfNeeded(modelContainer: ModelContainer) {
        guard !UserDefaults.standard.bool(forKey: completionKey) else { return }

        let legacyStoreURL = AppConstants.legacyApplicationSupportDirectory.appendingPathComponent("dictionary.store")
        guard FileManager.default.fileExists(atPath: legacyStoreURL.path) else {
            UserDefaults.standard.set(true, forKey: completionKey)
            return
        }

        do {
            let (words, replacements) = try readLegacyEntries(from: legacyStoreURL)
            let (addedWords, addedReplacements) = try merge(words: words, replacements: replacements, into: modelContainer.mainContext)
            UserDefaults.standard.set(true, forKey: completionKey)
            logger.notice("Migrated \(addedWords, privacy: .public) vocabulary word(s) and \(addedReplacements, privacy: .public) word replacement(s) from legacy store")
        } catch {
            logger.error("Legacy dictionary migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Reads from a temporary copy so the legacy store (and its WAL) is never modified.
    private func readLegacyEntries(from storeURL: URL) throws -> ([LegacyWord], [LegacyReplacement]) {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let copyURL = tempDirectory.appendingPathComponent(storeURL.lastPathComponent)
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.copyItem(at: source, to: URL(fileURLWithPath: copyURL.path + suffix))
        }

        let schema = Schema([VocabularyWord.self, WordReplacement.self])
        let configuration = ModelConfiguration("legacyDictionary", schema: schema, url: copyURL, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)

        let words = try context.fetch(FetchDescriptor<VocabularyWord>())
            .map { LegacyWord(word: $0.word, dateAdded: $0.dateAdded) }
        let replacements = try context.fetch(FetchDescriptor<WordReplacement>())
            .map { LegacyReplacement(originalText: $0.originalText, replacementText: $0.replacementText, dateAdded: $0.dateAdded, isEnabled: $0.isEnabled) }
        return (words, replacements)
    }

    /// Skips anything already present, using the same duplicate rules as `DictionaryService`.
    private func merge(words: [LegacyWord], replacements: [LegacyReplacement], into context: ModelContext) throws -> (Int, Int) {
        var knownWords = Set(try context.fetch(FetchDescriptor<VocabularyWord>()).map { $0.word.lowercased() })
        var addedWords = 0
        for legacy in words {
            let word = legacy.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, knownWords.insert(word.lowercased()).inserted else { continue }
            context.insert(VocabularyWord(word: word, dateAdded: legacy.dateAdded))
            addedWords += 1
        }

        func tokens(_ original: String) -> [String] {
            original
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        }

        var knownTokens = Set(try context.fetch(FetchDescriptor<WordReplacement>()).flatMap { tokens($0.originalText) })
        var addedReplacements = 0
        for legacy in replacements {
            let originalTokens = tokens(legacy.originalText)
            guard !originalTokens.isEmpty, !legacy.replacementText.isEmpty,
                  knownTokens.isDisjoint(with: originalTokens) else { continue }
            context.insert(WordReplacement(
                originalText: legacy.originalText,
                replacementText: legacy.replacementText,
                dateAdded: legacy.dateAdded,
                isEnabled: legacy.isEnabled
            ))
            knownTokens.formUnion(originalTokens)
            addedReplacements += 1
        }

        if context.hasChanges {
            try context.save()
        }
        return (addedWords, addedReplacements)
    }
}
