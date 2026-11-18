import SwiftUI

/// Settings for the models Speak falls back to when a mode's own model fails.
struct ModelFallbackSettingsSection: View {
    @EnvironmentObject private var aiService: AIService
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @AppStorage(ModelFallbackSettings.enhancementEnabledKey) private var isEnhancementFallbackEnabled = true
    @AppStorage(ModelFallbackSettings.transcriptionEnabledKey) private var isTranscriptionFallbackEnabled = true
    @AppStorage(ModelFallbackSettings.transcriptionModelKey) private var transcriptionFallbackKey = ""
    @State private var customFallbacks = ModelFallbackSettings.customEnhancementFallbacks

    /// The AI model the enhancing modes use, which automatic backups are chosen around.
    private var primary: (provider: AIProvider, model: String) {
        if let mode = ModeManager.shared.enabledConfigurations.first(where: \.isAIEnhancementEnabled),
            let providerName = mode.selectedAIProvider,
            let provider = AIProvider(rawValue: providerName)
        {
            return (provider, mode.selectedAIModel ?? provider.defaultModel)
        }
        return (aiService.selectedProvider, aiService.currentModel)
    }

    private var fallbacks: [EnhancementFallbackModel] {
        customFallbacks
            ?? ModelFallbackSettings.automaticEnhancementFallbacks(
                primary: primary.provider, model: primary.model, aiService: aiService)
    }

    private var onDeviceModels: [any TranscriptionModel] {
        transcriptionModelManager.usableModels.filter(ModelFallbackSettings.runsOnDevice)
    }

    var body: some View {
        Section {
            Toggle("Try Backup AI Models", isOn: $isEnhancementFallbackEnabled)

            if isEnhancementFallbackEnabled {
                ForEach(Array(fallbacks.enumerated()), id: \.element.id) { index, fallback in
                    HStack {
                        Text("\(index + 1).")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(fallback.model)
                            Text(fallback.providerName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            setFallbacks(fallbacks.filter { $0 != fallback })
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this backup")
                    }
                }

                if fallbacks.isEmpty {
                    Text("No backups. When the model fails, Speak pastes your words without enhancement.")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Menu("Add Backup Model") {
                        ForEach(aiService.connectedProviders.filter { $0 != .voiceInkRefine }, id: \.self) { provider in
                            Menu(provider.rawValue) {
                                ForEach(addableModels(for: provider), id: \.self) { model in
                                    Button(model) {
                                        setFallbacks(fallbacks + [EnhancementFallbackModel(provider: provider, model: model)])
                                    }
                                }
                            }
                        }
                    }
                    .fixedSize()

                    Spacer()

                    if customFallbacks != nil {
                        Button("Use Automatic") {
                            customFallbacks = nil
                            ModelFallbackSettings.customEnhancementFallbacks = nil
                        }
                    }
                }
            }

            Toggle("Transcribe on Device When the Cloud Fails", isOn: $isTranscriptionFallbackEnabled)

            if isTranscriptionFallbackEnabled {
                Picker("On-Device Model", selection: $transcriptionFallbackKey) {
                    Text(automaticTranscriptionLabel).tag("")
                    ForEach(onDeviceModels, id: \.selectionKey) { model in
                        Text(model.displayName).tag(model.selectionKey)
                    }
                }
            }
        } header: {
            Text("Backup Models")
        } footer: {
            Text(
                "When a model is rate-limited, out of quota or unreachable, Speak tries the backups in order. A model that hits its rate limit is skipped for a minute."
            )
        }
    }

    private var automaticTranscriptionLabel: String {
        let model = ModelFallbackSettings.automaticTranscriptionFallback(in: onDeviceModels)
        return String(format: String(localized: "Automatic (%@)"), model?.displayName ?? String(localized: "none downloaded"))
    }

    private func addableModels(for provider: AIProvider) -> [String] {
        var models = aiService.availableModels(for: provider)
        if provider == .ollama, models.isEmpty {
            models = [provider.defaultModel]
        }
        return models.filter { model in
            !fallbacks.contains { $0.provider == provider && $0.model == model }
                && !(provider == primary.provider && model == primary.model)
        }
    }

    private func setFallbacks(_ newValue: [EnhancementFallbackModel]) {
        customFallbacks = newValue
        ModelFallbackSettings.customEnhancementFallbacks = newValue
    }
}
