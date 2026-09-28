import Foundation

/// Placeholder for upstream's on-device "VoiceInk Refine" enhancement model.
///
/// The model weights are licensed for use with the VoiceInk application only, so Speak ships no
/// downloader, XPC service, or inference code for them. The provider always reports unavailable,
/// which keeps it out of provider pickers and Modes while the shared enhancement code compiles.
final class VoiceInkRefineService: ObservableObject {
    static let shared = VoiceInkRefineService()

    static let providerName = "VoiceInk Refine"
    static let modelName = "VoiceInk Refine V1"
    static let downloadSizeDescription = ""

    @Published private(set) var isDownloaded = false

    var isAvailableInModes: Bool { false }

    private init() {}

    func enhance(transcript: String) async throws -> String {
        throw VoiceInkRefineUnavailableError()
    }

    func deleteModel() async {}
    func prepareForRecording() async {}
    func keepPreparedModelWarmForRecording() async {}
    func unloadPreparedModelIfNeeded() async {}
}

struct VoiceInkRefineUnavailableError: LocalizedError {
    var errorDescription: String? {
        "VoiceInk Refine is not available in Speak."
    }
}
