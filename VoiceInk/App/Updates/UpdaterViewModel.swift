import AppKit
import Foundation
import SwiftUI

/// Speak ships without Sparkle; new versions are published as GitHub releases.
/// Keeps the interface the Dashboard, Settings, and menu bar expect.
@MainActor
final class UpdaterViewModel: ObservableObject {
    struct AvailableUpdate: Equatable {
        let versionIdentifier: String
        let displayVersion: String
    }

    private static let releasesURL = URL(string: "https://github.com/aryan-cs/speak/releases")!

    @Published var canCheckForUpdates = true
    // There is no update feed to probe, so the Dashboard never advertises an update.
    @Published private(set) var checksForUpdatesWhenDashboardAppears = false
    @Published private(set) var availableUpdate: AvailableUpdate?

    func setChecksForUpdatesWhenDashboardAppears(_ value: Bool) {}

    func checkForUpdatesIfDue() {}

    func checkForUpdates() {
        NSWorkspace.shared.open(Self.releasesURL)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject var updaterViewModel: UpdaterViewModel

    var body: some View {
        Button("Open GitHub Releases…", action: updaterViewModel.checkForUpdates)
            .disabled(!updaterViewModel.canCheckForUpdates)
    }
}
