import AppKit
import SwiftUI

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private var notificationWindow: NSPanel?
    private var dismissTimer: Timer?
    private var notificationID: UUID?
    /// Repositions the pop-up while the recorder resizes, e.g. when the live transcript appears.
    private var recorderFrameObserver: NSObjectProtocol?

    /// Gap between the pop-up and the top of the recorder pill.
    private static let gapAboveRecorder: CGFloat = 6

    private init() {}

    func showNotification(
        title: String,
        type: AppNotificationView.NotificationType,
        duration: TimeInterval = 3.0,
        onTap: (() -> Void)? = nil,
        actionButton: (label: String, systemImage: String, action: () -> Void)? = nil
    ) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        let notificationID = UUID()
        self.notificationID = notificationID

        if let existingWindow = notificationWindow {
            existingWindow.close()
            notificationWindow = nil
        }

        // Play esc sound for error notifications
        if type == .error {
            SoundManager.shared.playEscSound()
        }
        
        let usesExternalGlass: Bool
        if #available(macOS 26.0, *) {
            usesExternalGlass = true
        } else {
            usesExternalGlass = false
        }

        let notificationView = AppNotificationView(
            title: title,
            type: type,
            duration: duration,
            onClose: { [weak self] in
                Task { @MainActor in
                    self?.dismissNotification(ifCurrent: notificationID)
                }
            },
            onTap: onTap,
            actionButton: actionButton,
            usesExternalGlass: usesExternalGlass
        )
        let hostingController = NSHostingController(rootView: notificationView)
        let size = hostingController.view.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        if #available(macOS 26.0, *) {
            // Exactly the recorder pill's glass: no tint, capsule corners.
            panel.contentView = GlassHostView(
                contentView: hostingController.view,
                cornerRadius: size.height / 2
            )
        } else {
            panel.contentView = hostingController.view
        }
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level.mainMenu
        panel.backgroundColor = NSColor.clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false

        positionWindow(panel)
        observeRecorderFrame()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil as Any?)

        self.notificationWindow = panel

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        })

        // Schedule a new timer to dismiss the new notification.
        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: duration,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.dismissNotification(ifCurrent: notificationID)
            }
        }
    }

    private var visibleRecorderPanel: MiniRecorderPanel? {
        NSApp.windows.lazy.compactMap { $0 as? MiniRecorderPanel }.first { $0.isVisible }
    }

    /// Just above the recorder pill when it is showing, centered on it; otherwise where the
    /// pop-up would sit above a 40 pt pill at the bottom of the screen.
    private func positionWindow(_ window: NSWindow) {
        let size = window.frame.size
        if let recorder = visibleRecorderPanel {
            let recorderFrame = recorder.frame
            window.setFrameOrigin(
                NSPoint(
                    x: (recorderFrame.midX - size.width / 2).rounded(),
                    y: recorderFrame.maxY + Self.gapAboveRecorder
                ))
            return
        }

        let activeScreen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let screenRect = activeScreen.visibleFrame
        let recorderBottomMargin: CGFloat = 16
        let recorderHeight: CGFloat = 40
        window.setFrameOrigin(
            NSPoint(
                x: (screenRect.midX - size.width / 2).rounded(),
                y: screenRect.minY + recorderBottomMargin + recorderHeight + Self.gapAboveRecorder
            ))
    }

    private func observeRecorderFrame() {
        stopObservingRecorderFrame()
        guard let recorder = visibleRecorderPanel else { return }
        recorderFrameObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: recorder, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.notificationWindow else { return }
                self.positionWindow(window)
            }
        }
    }

    private func stopObservingRecorderFrame() {
        if let recorderFrameObserver {
            NotificationCenter.default.removeObserver(recorderFrameObserver)
            self.recorderFrameObserver = nil
        }
    }

    func dismissNotification() {
        guard let window = notificationWindow else { return }

        notificationWindow = nil
        notificationID = nil
        stopObservingRecorderFrame()

        dismissTimer?.invalidate()
        dismissTimer = nil

        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                window.animator().alphaValue = 0
            },
            completionHandler: {
                window.close()

            })
    }

    private func dismissNotification(ifCurrent notificationID: UUID) {
        guard self.notificationID == notificationID else { return }
        dismissNotification()
    }
}
