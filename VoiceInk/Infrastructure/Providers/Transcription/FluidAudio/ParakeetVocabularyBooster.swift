import CoreML
import FluidAudio
import Foundation
import os

/// Corrects Parakeet transcripts toward the dictionary's vocabulary with FluidAudio's CTC keyword
/// spotter. A word is replaced only when a second, CTC model hears the vocabulary term in that
/// stretch of audio more strongly than the word Parakeet wrote.
///
/// Three choices differ from FluidAudio's defaults, each measured on the user's recordings:
/// - The CTC model runs on the CPU. On the Neural Engine its output was garbage (all blank).
/// - Clips shorter than the model's 15 s window are filled with repeats of the clip. Silence
///   padding left clips under ~5 s with no usable output.
/// - The spotter-rescue pass is off, and a single everyday word needs a close spelling to the
///   term. Rescue replaced ordinary words ("code" → "Claude"); the spelling floor stops
///   "Include" → "Claude" while keeping "grok" → "Groq".
actor ParakeetVocabularyBooster {
    struct Evidence: Sendable {
        let logProbs: [[Float]]
        let frameDuration: Double
    }

    struct Replacement: Sendable {
        let original: String
        let term: String
    }

    static let shared = ParakeetVocabularyBooster()

    /// Samples in the CTC model's input window (15 s at 16 kHz).
    static let modelWindowSamples = 240_000
    /// Minimum spelling similarity for replacing a single everyday word.
    static let everydayWordMinimumSimilarity: Float = 0.70
    /// Longer audio is not boosted; the CTC pass would cost more than it saves.
    static let maximumBoostedSamples = 16_000 * 60 * 5
    private static let marginSeconds = 0.5

    private let logger = Logger(subsystem: AppConstants.logSubsystem, category: "VocabularyBoosting")
    private var ctcModels: CtcModels?
    private var tokenizer: CtcTokenizer?
    private var spotter: CtcKeywordSpotter?
    private var rescorer: VocabularyRescorer?
    private var vocabulary: CustomVocabularyContext?
    private var vocabularyTerms: [String] = []
    private var modelLoadTask: Task<Void, Error>?

    /// Loads (downloading on first use) the CTC model and builds the vocabulary. Cheap when the
    /// terms are unchanged.
    func prepare(terms: [String]) async throws {
        let terms = Self.normalizedTerms(terms)
        try await loadModelsIfNeeded()
        guard terms != vocabularyTerms || rescorer == nil else { return }
        guard let ctcModels, let tokenizer, let spotter else { return }

        vocabularyTerms = terms
        guard !terms.isEmpty else {
            vocabulary = nil
            rescorer = nil
            return
        }
        let context = CustomVocabularyContext(
            terms: terms.compactMap { term in
                let tokens = tokenizer.encode(term)
                return tokens.isEmpty ? nil : CustomVocabularyTerm(text: term, ctcTokenIds: tokens)
            }
        )
        vocabulary = context
        rescorer = try await VocabularyRescorer.create(
            spotter: spotter,
            vocabulary: context,
            config: VocabularyRescorer.Config(spotterRescueEnabled: false),
            ctcModelDirectory: CtcModels.defaultCacheDirectory(for: ctcModels.variant)
        )
        logger.notice("Vocabulary boosting ready terms=\(context.terms.count, privacy: .public)")
    }

    var isReady: Bool { rescorer != nil }
    var isModelLoaded: Bool { ctcModels != nil }

    /// Runs the CTC model over the audio Parakeet transcribes. Independent of the transcript, so
    /// it can run alongside Parakeet.
    func evidence(for samples: [Float]) async throws -> Evidence? {
        guard let spotter, let vocabulary, !samples.isEmpty,
            samples.count <= Self.maximumBoostedSamples
        else { return nil }

        let result = try await spotter.spotKeywordsWithLogProbs(
            audioSamples: Self.filledForModelWindow(samples),
            customVocabulary: vocabulary,
            minScore: nil
        )
        guard result.frameDuration > 0 else { return nil }
        let seconds = Double(samples.count) / Double(ASRConstants.sampleRate)
        let frames = min(result.logProbs.count, Int((seconds / result.frameDuration).rounded(.up)))
        return Evidence(logProbs: Array(result.logProbs.prefix(frames)), frameDuration: result.frameDuration)
    }

    /// Applies the replacements the audio supports to `transcript`, keeping its punctuation.
    func apply(
        _ evidence: Evidence,
        transcript: String,
        tokenTimings: [TokenTiming],
        isEverydayWord: @Sendable (String) async -> Bool
    ) async -> (text: String, replacements: [Replacement]) {
        guard let rescorer, let vocabulary, !tokenTimings.isEmpty, !evidence.logProbs.isEmpty else {
            return (transcript, [])
        }

        let sizeConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: vocabulary.terms.count)
        let output = rescorer.ctcTokenEvaluateCandidates(
            transcript: transcript,
            tokenTimings: tokenTimings,
            logProbs: evidence.logProbs,
            frameDuration: evidence.frameDuration,
            cbw: sizeConfig.cbw,
            marginSeconds: Self.marginSeconds,
            minSimilarity: max(sizeConfig.minSimilarity, vocabulary.minSimilarity)
        )

        var accepted: [(range: Range<Int>, replacement: Replacement)] = []
        for candidate in output.candidates where candidate.legacyOutcome == .applied {
            guard let range = candidate.baseTextUTF8Range else { continue }
            let phrase = candidate.basePhrase
            if !phrase.contains(where: \.isWhitespace),
                candidate.similarity < Self.everydayWordMinimumSimilarity,
                await isEverydayWord(phrase)
            {
                continue
            }
            accepted.append((range, Replacement(original: phrase, term: candidate.canonicalTerm)))
        }

        var utf8 = Array(output.baseText.utf8)
        var lastStart = Int.max
        for (range, replacement) in accepted.sorted(by: { $0.range.lowerBound > $1.range.lowerBound })
        where range.upperBound <= lastStart && range.upperBound <= utf8.count {
            utf8.replaceSubrange(range, with: Array(replacement.term.utf8))
            lastStart = range.lowerBound
        }
        let text = String(decoding: utf8, as: UTF8.self)
        return (text, text == transcript ? [] : accepted.map(\.replacement))
    }

    /// The CTC model reads 15 s windows and pads a short window with silence, which leaves it
    /// with no usable output. A short clip is repeated to fill the window; longer audio gets a
    /// window of its own start appended, so the last window is full too. Only frames for the
    /// real audio are kept.
    static func filledForModelWindow(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        guard samples.count < modelWindowSamples else {
            return samples + samples.prefix(modelWindowSamples)
        }
        var filled = samples
        filled.reserveCapacity(modelWindowSamples)
        while filled.count < modelWindowSamples {
            filled += samples.prefix(modelWindowSamples - filled.count)
        }
        return filled
    }

    static func normalizedTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .sorted()
    }

    private func loadModelsIfNeeded() async throws {
        if ctcModels != nil { return }
        if let modelLoadTask {
            try await modelLoadTask.value
            return
        }
        let task = Task { try await self.loadModels() }
        modelLoadTask = task
        defer { modelLoadTask = nil }
        try await task.value
    }

    private func loadModels() async throws {
        let start = Date()
        _ = try await CtcModels.download(variant: .ctc110m)
        let directory = CtcModels.defaultCacheDirectory(for: .ctc110m)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let vocabularyData = try Data(contentsOf: directory.appendingPathComponent("vocab.json"))
        let tokens = try JSONSerialization.jsonObject(with: vocabularyData) as? [String: String] ?? [:]
        let models = CtcModels(
            melSpectrogram: try MLModel(
                contentsOf: directory.appendingPathComponent("MelSpectrogram.mlmodelc"),
                configuration: configuration
            ),
            encoder: try MLModel(
                contentsOf: directory.appendingPathComponent("AudioEncoder.mlmodelc"),
                configuration: configuration
            ),
            configuration: configuration,
            vocabulary: Dictionary(uniqueKeysWithValues: tokens.compactMap { key, value in
                Int(key).map { ($0, value) }
            }),
            variant: .ctc110m
        )
        tokenizer = try await CtcTokenizer.load(from: directory)
        spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        ctcModels = models
        logger.notice(
            "Vocabulary boosting model loaded in \(String(format: "%.1f", Date().timeIntervalSince(start)), privacy: .public)s"
        )
    }
}
