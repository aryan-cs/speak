import Foundation

enum AppConstants {
    static let bundleIdentifier = "com.aryancs.Speak"
    static let logSubsystem = "com.aryancs.speak"
    static let cloudKitContainerIdentifier = "iCloud.com.aryancs.Speak"

    static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    static var recordingsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }
}
