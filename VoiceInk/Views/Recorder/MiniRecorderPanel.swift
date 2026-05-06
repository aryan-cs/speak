import SwiftUI
import AppKit

class MiniRecorderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configurePanel()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }
    
    private func configurePanel() {
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        appearance = nil
        hasShadow = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
    }
    
    static func calculateWindowMetrics(contentSize: NSSize) -> NSRect {
        guard let screen = targetScreen else {
            return NSRect(origin: .zero, size: contentSize)
        }

        let dockClearance: CGFloat = 84
        let visibleFramePadding: CGFloat = 20

        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let centerX = visibleFrame.midX
        let xPosition = centerX - (contentSize.width / 2)
        let yPosition: CGFloat
        if visibleFrame.minY > screenFrame.minY {
            yPosition = visibleFrame.minY + visibleFramePadding
        } else {
            yPosition = screenFrame.minY + dockClearance
        }

        return NSRect(
            x: xPosition.rounded(),
            y: yPosition.rounded(),
            width: contentSize.width,
            height: contentSize.height
        )
    }

    private static var targetScreen: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main ?? NSScreen.screens.first
    }

    func show(contentSize: NSSize? = nil) {
        setFrame(
            MiniRecorderPanel.calculateWindowMetrics(contentSize: contentSize ?? frame.size),
            display: true
        )
        orderFrontRegardless()
    }

    func updateContentSize(_ contentSize: NSSize) {
        let metrics = MiniRecorderPanel.calculateWindowMetrics(contentSize: contentSize)
        setFrame(metrics, display: true)
    }
    
    func hide(completion: @escaping () -> Void) {
        completion()
    }

    @objc private func handleScreenParametersChange() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.setFrame(
                MiniRecorderPanel.calculateWindowMetrics(contentSize: self.frame.size),
                display: true
            )
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
