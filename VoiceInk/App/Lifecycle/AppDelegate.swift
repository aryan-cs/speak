import Cocoa
import SwiftUI
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var menuBarManager: MenuBarManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarManager?.applyActivationPolicy()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let menuBarManager else { return true }
        let showsDockIcon = !menuBarManager.isMenuBarOnly
        // Without a Dock or menu bar icon, opening Speak again is the way back to its window.
        guard showsDockIcon || !MenuBarIconPreference.isVisible else { return true }

        if !showsDockIcon {
            menuBarManager.activateForPresentedWindow()
        }
        if WindowManager.shared.currentMainWindow() != nil {
            WindowManager.shared.showMainWindow()
            return false
        }

        WindowManager.shared.prepareForUserRequestedMainWindow()
        NotificationCenter.default.post(name: .showMainWindowRequested, object: nil)
        // With the menu bar icon hidden no bridge may be listening, so SwiftUI reopens the window.
        return !MenuBarIconPreference.isVisible
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // Stash URL when app cold-starts to avoid spawning a new window/tab
    var pendingOpenFileURL: URL?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { SupportedMedia.isSupported(url: $0) }) else {
            return
        }

        if let menuBarManager {
            menuBarManager.activateForPresentedWindow()
        } else {
            AppPresentationPolicy.activateForUserFacingWindow()
        }

        if WindowManager.shared.currentMainWindow() == nil {
            // Cold start: do NOT create a window here to avoid extra window/tab.
            // Defer to SwiftUI's main window scene and let ContentView process this later.
            pendingOpenFileURL = url
            WindowManager.shared.prepareForUserRequestedMainWindow()
            NotificationCenter.default.post(name: .showMainWindowRequested, object: nil)
        } else {
            // Running: focus current window and route in-place to Transcribe Audio
            WindowManager.shared.showMainWindow()
            NotificationCenter.default.post(
                name: .navigateToDestination, object: nil, userInfo: ["destination": "Transcribe Audio"])
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openFileForTranscription, object: nil, userInfo: ["url": url])
            }
        }
    }
}
