import FluidAudio
import Foundation
import os.log

class FluidAudioTranscriptionService: TranscriptionService {
    private var asrManager: AsrManager?
    private var unifiedAsrManager: UnifiedAsrManager?
    private var nemotronAsrManager: StreamingNemotronMultilingualAsrManager?
    private var vadManager: VadManager?
    private var activeVersion: AsrModelVersion?
    private var activeNemotronModelName: String?
    private var cachedModels: AsrModels?
    private var loadingTask: (version: AsrModelVersion, task: Task<AsrModels, Error>)?
    private let audioConverter = AudioConverter()
    private let logger = Logger(subsystem: AppConstants.logSubsystem, category: "FluidAudioTranscriptionService")
    /// The dictionary's vocabulary words, for correcting Parakeet transcripts toward them.
    private let vocabularyTerms: (@MainActor () -> [String])?

    init(vocabularyTerms: (@MainActor () -> [String])? = nil) {
        self.vocabularyTerms = vocabularyTerms
    }

    private func version(for model: any TranscriptionModel) -> AsrModelVersion {
        FluidAudioModelManager.asrVersion(for: model.name)
    }

    static func languageHint(from selectedLanguage: String?, model: any TranscriptionModel) -> Language? {
        guard model.provider == .fluidAudio else {
            return nil
        }
        return FluidAudioModelManager.languageHint(from: selectedLanguage, for: model.name)
    }

    private func cleanupLoadedManagers() async {
        await unifiedAsrManager?.cleanup()
        await nemotronAsrManager?.cleanup()
        await asrManager?.cleanup()

        unifiedAsrManager = nil
        nemotronAsrManager = nil
        asrManager = nil
        vadManager = nil
        activeVersion = nil
        activeNemotronModelName = nil
    }

    private func ensureModelsLoaded(for version: AsrModelVersion) async throws {
        if asrManager != nil, activeVersion == version {
            return
        }

        // Clean up existing manager but preserve cachedModels for reuse
        await cleanupLoadedManagers()

        let models = try await getOrLoadModels(for: version)

        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asrManager = manager
        self.activeVersion = version
    }

    private func ensureUnifiedModelsLoaded() async throws {
        if unifiedAsrManager != nil {
            return
        }

        await cleanupLoadedManagers()

        let manager = UnifiedAsrManager(encoderPrecision: FluidAudioModelManager.parakeetUnifiedPrecision)
        try await manager.loadModels(from: FluidAudioModelManager.parakeetUnifiedCacheDirectory())
        self.unifiedAsrManager = manager
    }

    private func ensureNemotronModelsLoaded(named modelName: String) async throws {
        if nemotronAsrManager != nil, activeNemotronModelName == modelName {
            return
        }

        await cleanupLoadedManagers()

        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadModels(from: FluidAudioModelManager.nemotronCacheDirectory(for: modelName))
        self.nemotronAsrManager = manager
        self.activeNemotronModelName = modelName
    }

    // Returns cached models or loads from disk; deduplicates concurrent loads
    func getOrLoadModels(for version: AsrModelVersion) async throws -> AsrModels {
        if let cached = cachedModels, cached.version == version {
            return cached
        }

        // Deduplicate concurrent loads for the same version
        if let (existingVersion, existingTask) = loadingTask, existingVersion == version {
            return try await existingTask.value
        }

        let task = Task {
            let cacheDirectory = AsrModels.defaultCacheDirectory(for: version)
            guard AsrModels.modelsExist(at: cacheDirectory, version: version) else {
                throw AsrModelsError.loadingFailed(
                    "Parakeet model files are incomplete. Download the model from AI Models."
                )
            }
            return try await AsrModels.load(
                from: cacheDirectory,
                configuration: nil,
                version: version,
                encoderPrecision: .int8
            )
        }
        loadingTask = (version, task)

        do {
            let models = try await task.value
            self.cachedModels = models
            // Only clear if we're still the current loading task
            if loadingTask?.version == version {
                self.loadingTask = nil
            }
            return models
        } catch {
            // Only clear if we're still the current loading task
            if loadingTask?.version == version {
                self.loadingTask = nil
            }
            throw error
        }
    }

    func loadModel(for model: FluidAudioModel) async throws {
        if FluidAudioModelManager.isNemotronModel(named: model.name) {
            // Realtime Nemotron uses a dedicated streaming manager; batch loads lazily in transcribe().
            return
        }

        if FluidAudioModelManager.isParakeetUnifiedModel(named: model.name) {
            try await ensureUnifiedModelsLoaded()
            return
        }

        try await ensureModelsLoaded(for: version(for: model))
        warmUpVocabularyBoosting()
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws
        -> String
    {
        if FluidAudioModelManager.isParakeetUnifiedModel(named: model.name) {
            try await ensureUnifiedModelsLoaded()
            guard let unifiedAsrManager else {
                throw ASRError.notInitialized
            }

            let speechAudio = try await preparedSpeechAudio(from: audioURL)
            guard !speechAudio.isEmpty else { return "" }
            let text = try await unifiedAsrManager.transcribe(speechAudio)
            return text
        }

        if FluidAudioModelManager.isNemotronModel(named: model.name) {
            try await ensureNemotronModelsLoaded(named: model.name)
            guard let nemotronAsrManager else {
                throw ASRError.notInitialized
            }

            let compatibleLanguage = TranscriptionLanguageSupport.validLanguageOrFallback(
                context.language,
                for: model
            )
            let languageHint = FluidAudioModelManager.nemotronLanguageHint(from: compatibleLanguage)
            await nemotronAsrManager.setLanguage(languageHint)
            await nemotronAsrManager.reset()

            var speechAudio = try await preparedSpeechAudio(from: audioURL)
            guard !speechAudio.isEmpty else { return "" }
            let trailingSilenceSamples = 16_000
            let maxSingleChunkSamples = 240_000
            if speechAudio.count + trailingSilenceSamples <= maxSingleChunkSamples {
                speechAudio += [Float](repeating: 0, count: trailingSilenceSamples)
            }

            _ = try await nemotronAsrManager.process(samples: speechAudio)
            let text = try await nemotronAsrManager.finish()
            return text
        }

        let targetVersion = version(for: model)
        try await ensureModelsLoaded(for: targetVersion)

        guard let asrManager = asrManager else {
            throw ASRError.notInitialized
        }

        let languageHint = Self.languageHint(
            from: context.language,
            model: model
        )
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let booster = await readyVocabularyBooster()
        let samples: [Float]?
        if UserDefaults.standard.bool(forKey: "IsVADEnabled") {
            samples = try await preparedSpeechAudio(from: audioURL)
        } else {
            samples = booster == nil ? nil : try loadAudioSamples(from: audioURL)
        }
        if let samples, samples.isEmpty { return "" }

        // The CTC pass needs only the audio, so it runs alongside Parakeet.
        async let evidence: ParakeetVocabularyBooster.Evidence? = {
            guard let booster, let samples else { return nil }
            return try? await booster.evidence(for: samples)
        }()

        let result: ASRResult
        if let samples {
            result = try await asrManager.transcribe(samples, decoderState: &decoderState, language: languageHint)
        } else {
            result = try await asrManager.transcribe(audioURL, decoderState: &decoderState, language: languageHint)
        }

        guard let booster, let evidence = await evidence else { return result.text }
        let boostStart = Date()
        let boosted = await booster.apply(
            evidence,
            transcript: result.text,
            tokenTimings: result.tokenTimings ?? [],
            isEverydayWord: { word in await AutoLearnEverydayWordGuard.isEverydayWord(word) }
        )
        logger.notice(
            "Vocabulary boosting replaced=\(boosted.replacements.count, privacy: .public) wait=\(Int(Date().timeIntervalSince(boostStart) * 1000), privacy: .public)ms"
        )
        return boosted.text
    }

    /// The booster when it is ready for the current vocabulary. Loading the CTC model can take
    /// seconds, so that happens in the background and this transcription goes unboosted.
    private func readyVocabularyBooster() async -> ParakeetVocabularyBooster? {
        guard VocabularyBoostingSettings.isEnabled, let vocabularyTerms else { return nil }
        let terms = await MainActor.run { vocabularyTerms() }
        guard !terms.isEmpty else { return nil }

        let booster = ParakeetVocabularyBooster.shared
        guard await booster.isModelLoaded else {
            warmUpVocabularyBoosting()
            return nil
        }
        do {
            try await booster.prepare(terms: terms)
        } catch {
            logger.error("Vocabulary boosting unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return await booster.isReady ? booster : nil
    }

    /// Loads the CTC model ahead of the first dictation.
    func warmUpVocabularyBoosting() {
        guard VocabularyBoostingSettings.isEnabled, let vocabularyTerms else { return }
        let logger = logger
        Task.detached(priority: .utility) {
            let terms = await MainActor.run { vocabularyTerms() }
            guard !terms.isEmpty else { return }
            do {
                try await ParakeetVocabularyBooster.shared.prepare(terms: terms)
            } catch {
                logger.error("Vocabulary boosting model failed to load: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func loadAudioSamples(from audioURL: URL) throws -> [Float] {
        try audioConverter.resampleAudioFile(audioURL)
    }

    private func preparedSpeechAudio(from audioURL: URL) async throws -> [Float] {
        let samples = try loadAudioSamples(from: audioURL)
        return try await preparedSpeechAudio(in: samples)
    }

    func preparedSpeechAudio(in samples: [Float]) async throws -> [Float] {
        guard let segments = try await detectedSpeechAudio(in: samples) else {
            return samples
        }

        var speechAudio = segments.flatMap { $0 }
        guard !speechAudio.isEmpty else { return [] }
        let minimumSamples = ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate)
        if speechAudio.count < minimumSamples {
            speechAudio += [Float](repeating: 0, count: minimumSamples - speechAudio.count)
        }
        return speechAudio
    }

    // Streaming callers retain each segment's original position for word timestamps.
    func detectedSpeechSegments(in samples: [Float]) async throws -> [VadSegment]? {
        guard UserDefaults.standard.bool(forKey: "IsVADEnabled") else {
            return nil
        }

        do {
            try Task.checkCancellation()
            let manager = try await getOrLoadVadManager()
            let segments = try await manager.segmentSpeech(samples)
            try Task.checkCancellation()
            return segments
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.notice("VAD failed; using full audio: \(error, privacy: .public)")
            return nil
        }
    }

    private func getOrLoadVadManager() async throws -> VadManager {
        if let vadManager { return vadManager }
        let manager = try await VadManager(config: VadConfig(defaultThreshold: 0.7))
        vadManager = manager
        return manager
    }

    // Nil means VAD is disabled or unavailable; callers preserve the original audio.
    private func detectedSpeechAudio(in samples: [Float]) async throws -> [[Float]]? {
        guard UserDefaults.standard.bool(forKey: "IsVADEnabled") else {
            return nil
        }

        do {
            try Task.checkCancellation()
            let manager = try await getOrLoadVadManager()
            let segments = try await manager.segmentSpeechAudio(samples)
            try Task.checkCancellation()
            return segments
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.notice("VAD failed; using full audio: \(error, privacy: .public)")
            return nil
        }
    }

    // Releases ASR/VAD resources but preserves cached models for reuse
    func cleanup() async {
        await cleanupLoadedManagers()
    }

}
