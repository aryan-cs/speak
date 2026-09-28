import AppKit
import SwiftUI
import os

@MainActor
class MiniWindowManager: ObservableObject {
    private static let compactContentSize = NSSize(width: 112, height: 40)

    @Published var isVisible = false
    private var windowController: NSWindowController?
    private var panel: MiniRecorderPanel?
    private weak var glassHost: NSView?
    private var contentSize = MiniWindowManager.compactContentSize

    private let makeView: (MiniWindowManager) -> AnyView
    private let logger = Logger(subsystem: AppConstants.logSubsystem, category: "MiniWindowManager")

    init(
        engine: VoiceInkEngine,
        recorder: Recorder,
        assistantSession: AssistantSession,
        onRecordButtonTapped: @escaping () -> Void,
        onCloseTapped: @escaping () -> Void,
        onAssistantFollowUp: @escaping (String) -> Void
    ) {
        self.makeView = { manager in
            let usesExternalGlass: Bool
            if #available(macOS 26.0, *) {
                usesExternalGlass = true
            } else {
                usesExternalGlass = false
            }

            return AnyView(
                MiniRecorderView(
                    stateProvider: engine,
                    recorder: recorder,
                    assistantSession: assistantSession,
                    onRecordButtonTapped: onRecordButtonTapped,
                    onCloseTapped: onCloseTapped,
                    onAssistantFollowUp: onAssistantFollowUp,
                    usesExternalGlass: usesExternalGlass
                )
                .environmentObject(manager)
            )
        }
    }

    /// Builds a fresh panel whenever one is not already on screen, so a window that stopped
    /// rendering after sleep/wake or a display reconfiguration can never survive into the next
    /// dictation.
    @discardableResult
    func show() -> Bool {
        if panel == nil { initializeWindow() }
        guard let panel else { return false }
        isVisible = true
        return panel.show(contentSize: contentSize)
    }

    /// Tears the window down rather than just ordering it out, so no panel is carried across
    /// dictations. The assistant conversation lives in `AssistantSession` and survives.
    func hide() {
        deinitializeWindow()
    }

    func destroyWindow() {
        deinitializeWindow()
    }

    private func initializeWindow() {
        deinitializeWindow()
        guard let metrics = MiniRecorderPanel.calculateWindowMetrics(contentSize: contentSize) else {
            logger.error("Mini panel not created: no screen available")
            return
        }
        let newPanel = MiniRecorderPanel(contentRect: metrics)
        let hostingController = NSHostingController(rootView: makeView(self))

        if #available(macOS 26.0, *) {
            let host = GlassHostView(
                contentView: hostingController.view,
                cornerRadius: contentSize.height / 2
            )
            newPanel.contentView = host
            glassHost = host
        } else {
            newPanel.contentView = hostingController.view
        }

        panel = newPanel
        windowController = NSWindowController(window: newPanel)
    }

    private func deinitializeWindow() {
        isVisible = false
        panel?.orderOut(nil)
        windowController?.close()
        windowController = nil
        panel = nil
        glassHost = nil
        // Start the next dictation compact; the view resyncs its real size on appear.
        contentSize = Self.compactContentSize
    }

    func updateContentMetrics(width: CGFloat, height: CGFloat, cornerRadius: CGFloat) {
        let nextSize = NSSize(width: width, height: height)
        if contentSize != nextSize {
            contentSize = nextSize
            panel?.updateContentSize(nextSize)
        }

        if #available(macOS 26.0, *) {
            (glassHost as? GlassHostView)?.cornerRadius = cornerRadius
        }
    }
}
