import AppKit
import SwiftUI

class MenuBarManager: ObservableObject {
    @Published var isMenuBarOnly: Bool {
        didSet {
            UserDefaults.standard.set(isMenuBarOnly, forKey: "IsMenuBarOnly")
            applyActivationPolicy()
        }
    }

    private var engine: VoiceInkEngine?
    private var configuredActivationPolicy: NSApplication.ActivationPolicy {
        isMenuBarOnly ? .accessory : .regular
    }

    init() {
        self.isMenuBarOnly = UserDefaults.standard.bool(forKey: "IsMenuBarOnly")
        applyActivationPolicy()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userFacingWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func userFacingWindowWillClose(_ notification: Notification) {
        guard isMenuBarOnly,
            let window = notification.object as? NSWindow,
            window.level == .normal,
            window.styleMask.contains(.titled)
        else {
            return
        }

        AppPresentationPolicy.restoreAccessoryIfNeededAfterUserFacingWindowClosed()
    }

    func configure(engine: VoiceInkEngine) {
        self.engine = engine
    }

    func toggleMenuBarOnly() {
        isMenuBarOnly.toggle()
    }

    func applyActivationPolicy() {
        let applyPolicy = { [weak self] in
            guard let self else { return }

            NSApplication.shared.setActivationPolicy(self.configuredActivationPolicy)

            if self.isMenuBarOnly {
                WindowManager.shared.hideMainWindow()
            }
        }

        if Thread.isMainThread {
            applyPolicy()
        } else {
            DispatchQueue.main.async(execute: applyPolicy)
        }
    }

    func activateForPresentedWindow() {
        let activate = {
            AppPresentationPolicy.activateForUserFacingWindow()
        }

        if Thread.isMainThread {
            activate()
        } else {
            DispatchQueue.main.async(execute: activate)
        }
    }

    func openQuickHistory() {
        guard let engine else { return }

        // Let the MenuBarExtra close before making the nonactivating panel key.
        DispatchQueue.main.async {
            QuickHistoryController.shared.show(modelContext: engine.modelContext, engine: engine)
        }
    }
}

/// Whether Speak's icon is in the menu bar; hidden, Speak is reached by opening it again.
/// The app scene owns the live value as plain state: binding `MenuBarExtra` to an
/// `ObservableObject` republishes during SwiftUI's own updates and never settles.
enum MenuBarIconPreference {
    static let key = "IsMenuBarIconVisible"

    static var isVisible: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

private struct MenuBarIconVisibilityKey: EnvironmentKey {
    static let defaultValue: Binding<Bool> = .constant(true)
}

extension EnvironmentValues {
    /// The app scene's menu bar icon state, for the menu and Settings to change.
    var menuBarIconVisibility: Binding<Bool> {
        get { self[MenuBarIconVisibilityKey.self] }
        set { self[MenuBarIconVisibilityKey.self] = newValue }
    }
}
