import Foundation

/// A backup AI model to try when the one a mode uses is rate-limited, out of quota or unreachable.
struct EnhancementFallbackModel: Codable, Hashable, Identifiable {
    let providerName: String
    let model: String

    init(provider: AIProvider, model: String) {
        self.providerName = provider.rawValue
        self.model = model
    }

    var id: String { "\(providerName)/\(model)" }
    var provider: AIProvider? { AIProvider(rawValue: providerName) }
}

/// Which models Speak falls back to, in order, when the one a mode uses fails.
enum ModelFallbackSettings {
    static let enhancementEnabledKey = "EnhancementFallbackEnabled"
    static let enhancementModelsKey = "EnhancementFallbackModels"
    static let transcriptionEnabledKey = "TranscriptionFallbackEnabled"
    static let transcriptionModelKey = "TranscriptionFallbackModel"

    static var isEnhancementFallbackEnabled: Bool {
        UserDefaults.standard.object(forKey: enhancementEnabledKey) as? Bool ?? true
    }

    static var isTranscriptionFallbackEnabled: Bool {
        UserDefaults.standard.object(forKey: transcriptionEnabledKey) as? Bool ?? true
    }

    /// The backups the user picked, or nil when Speak chooses them automatically.
    static var customEnhancementFallbacks: [EnhancementFallbackModel]? {
        get {
            guard let data = UserDefaults.standard.data(forKey: enhancementModelsKey) else { return nil }
            return try? JSONDecoder().decode([EnhancementFallbackModel].self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: enhancementModelsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: enhancementModelsKey)
            }
        }
    }

    /// The provider's other models, which have their own rate limits, then the local Ollama model.
    @MainActor
    static func automaticEnhancementFallbacks(
        primary: AIProvider, model: String, aiService: AIService
    ) -> [EnhancementFallbackModel] {
        var fallbacks: [EnhancementFallbackModel] = []
        if ![.ollama, .openRouter, .custom, .localCLI, .voiceInkRefine].contains(primary) {
            fallbacks += primary.availableModels
                .filter { $0 != model }
                .map { EnhancementFallbackModel(provider: primary, model: $0) }
        }
        if primary != .ollama, aiService.connectedProviders.contains(.ollama) {
            fallbacks.append(EnhancementFallbackModel(provider: .ollama, model: AIProvider.ollama.defaultModel))
        }
        return fallbacks
    }

    /// The models to try after the mode's own, in order.
    @MainActor
    static func enhancementFallbacks(primary: AIProvider, model: String, aiService: AIService)
        -> [EnhancementFallbackModel]
    {
        guard isEnhancementFallbackEnabled else { return [] }
        let fallbacks =
            customEnhancementFallbacks
            ?? automaticEnhancementFallbacks(primary: primary, model: model, aiService: aiService)
        return fallbacks.filter { !($0.provider == primary && $0.model == model) }
    }

    static func runsOnDevice(_ model: any TranscriptionModel) -> Bool {
        [.whisper, .fluidAudio, .transcribeCpp, .nativeApple].contains(model.provider)
    }

    /// The on-device model to transcribe with when a cloud model fails, or nil when that is off,
    /// the model already runs on device, or no on-device model is downloaded.
    static func transcriptionFallback(
        for model: any TranscriptionModel, usableModels: [any TranscriptionModel]
    ) -> (any TranscriptionModel)? {
        guard isTranscriptionFallbackEnabled, !runsOnDevice(model) else { return nil }
        let onDevice = usableModels.filter(runsOnDevice)
        if let chosen = UserDefaults.standard.string(forKey: transcriptionModelKey),
            let match = onDevice.first(where: { $0.selectionKey == chosen })
        {
            return match
        }
        return automaticTranscriptionFallback(in: onDevice)
    }

    /// The default model when it runs on device, else a downloaded Parakeet model, else any.
    static func automaticTranscriptionFallback(in onDevice: [any TranscriptionModel]) -> (any TranscriptionModel)? {
        let defaultKey = UserDefaults.standard.string(forKey: "CurrentTranscriptionModel")
        return onDevice.first { $0.selectionKey == defaultKey }
            ?? onDevice.first { $0.provider == .fluidAudio }
            ?? onDevice.first { $0.provider != .nativeApple }
            ?? onDevice.first
    }
}

/// Models that just answered "rate limit exceeded" are skipped for a minute, so the next dictation
/// goes straight to a backup instead of waiting on another refusal.
@MainActor
enum ModelCooldowns {
    static let rateLimitSeconds: TimeInterval = 60
    private static var coolingUntil: [String: Date] = [:]

    static func coolDown(provider: AIProvider, model: String, seconds: TimeInterval = rateLimitSeconds) {
        coolingUntil["\(provider.rawValue)/\(model)"] = Date().addingTimeInterval(seconds)
    }

    static func isCoolingDown(provider: AIProvider, model: String) -> Bool {
        guard let until = coolingUntil["\(provider.rawValue)/\(model)"] else { return false }
        return until > Date()
    }
}
