// Stand-ins for the app types Speak's capture files reference.
enum AppConstants { static let logSubsystem = "com.aryancs.speak.e2e" }
enum AIProvider { case ollama, voiceInkRefine
    var supportsEnhancement: Bool { self != .voiceInkRefine }
}
enum AutoLearnSettings { static var selectedProvider: AIProvider? { .ollama } }
