import SwiftUI
import AppKit

class MiniRecorderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var dockTrackingTimer: Timer?
    private var lastContentSize: NSSize?

    /// Hysteresis state for autohide-dock reveal detection.
    private var dockRevealed = false
    /// The reveal state last applied to the pill's frame; used to animate only on transitions.
    private var lastAppliedRevealed: Bool?
    /// Cached revealed-dock height (incl. padding), refreshed each time the pill is shown.
    private var revealedDockHeight: CGFloat = 84
    /// Whether the Dock is oriented at the bottom (vs. left/right). Side docks never push the pill up.
    private var dockOrientationIsBottom = true

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configurePanel()
        refreshDockPrefs()
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
        // NOTE: `.stationary` was removed because it bound the pill to the Space it was created in —
        // it would stay put during a Space-switch swipe (looking "stationary") and then vanish once
        // the new Space settled, leaving it only on the original Space. `[.canJoinAllSpaces,
        // .fullScreenAuxiliary]` (matching the working DictionaryQuickAddPanel) makes it appear on
        // every Space, including over full-screen apps. The `.floating` level is kept so the pill
        // stays below the Dock in z-order, avoiding overlap when the Dock reveals.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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

    // MARK: - Geometry

    /// Static entry used to size the window at creation time. Defaults to the dock-hidden position;
    /// the instance's dock-tracking timer takes over once the panel is shown.
    static func calculateWindowMetrics(contentSize: NSSize) -> NSRect {
        guard let screen = targetScreen else {
            return NSRect(origin: .zero, size: contentSize)
        }
        let visibleFrame = screen.visibleFrame
        let xPosition = visibleFrame.midX - (contentSize.width / 2)
        let yPosition = bottomYPosition(on: screen, dockRevealed: false, revealedDockHeight: 84)
        return NSRect(
            x: xPosition.rounded(),
            y: yPosition.rounded(),
            width: contentSize.width,
            height: contentSize.height
        )
    }

    private func metrics(contentSize: NSSize) -> NSRect {
        guard let screen = MiniRecorderPanel.targetScreen else {
            return NSRect(origin: frame.origin, size: contentSize)
        }
        let visibleFrame = screen.visibleFrame
        let xPosition = visibleFrame.midX - (contentSize.width / 2)
        let yPosition = MiniRecorderPanel.bottomYPosition(
            on: screen,
            dockRevealed: dockRevealed,
            revealedDockHeight: revealedDockHeight
        )
        return NSRect(
            x: xPosition.rounded(),
            y: yPosition.rounded(),
            width: contentSize.width,
            height: contentSize.height
        )
    }

    /// Computes the pill's bottom-left Y on the target screen.
    /// - Pinned (non-autohide) bottom dock: sit above the reserved dock area (uses `visibleFrame`).
    /// - Autohide dock currently revealed: sit above the revealed dock strip.
    /// - Otherwise (dock hidden / on a side / different screen): hug the bottom.
    private static func bottomYPosition(
        on screen: NSScreen,
        dockRevealed: Bool,
        revealedDockHeight: CGFloat
    ) -> CGFloat {
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame

        let noDockBottomMargin: CGFloat = 16
        let pinnedDockPadding: CGFloat = 20
        let aboveRevealedDockGap: CGFloat = 12

        // Case 1: a pinned (non-autohide) dock reserves space at the bottom of this screen.
        if visibleFrame.minY > screenFrame.minY {
            return visibleFrame.minY + pinnedDockPadding
        }

        // Case 2: autohide dock currently revealed under the cursor on this screen.
        if dockRevealed {
            return screenFrame.minY + revealedDockHeight + aboveRevealedDockGap
        }

        // Case 3: dock hidden / on a side / different screen — hug the bottom.
        return screenFrame.minY + noDockBottomMargin
    }

    private static var targetScreen: NSScreen? {
        if let mainScreen = NSScreen.main {
            return mainScreen
        }
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.screens.first
    }

    // MARK: - Dock preference reading

    /// Reads the live Dock size/orientation from `com.apple.dock` and caches the revealed height.
    /// Cheap enough to call once per show(); not called on every timer tick.
    private func refreshDockPrefs() {
        let defaults = UserDefaults(suiteName: "com.apple.dock")
        let orientation = defaults?.string(forKey: "orientation") ?? "bottom"
        dockOrientationIsBottom = (orientation == "bottom")

        let tile = CGFloat(defaults?.double(forKey: "tilesize") ?? 0)
        let large = CGFloat(defaults?.double(forKey: "largesize") ?? 0)
        let magnification = defaults?.bool(forKey: "magnification") ?? false

        let baseTile = tile > 0 ? tile : 48
        // With magnification on, a hovered icon grows up to `largesize` and pokes above the dock
        // baseline, so clear the larger of the two. The extra ~24pt covers the dock's own chrome
        // (padding, separators, reflection).
        let effectiveTile = (magnification && large > baseTile) ? large : baseTile
        revealedDockHeight = effectiveTile + 24
    }

    // MARK: - Autohide-dock reveal detection (mouse-based, with hysteresis)

    /// Returns whether an autohide bottom dock should be considered "revealed" on `screen`,
    /// based on the cursor position. Uses hysteresis: it reveals only when the cursor hits the very
    /// bottom edge (mirroring how macOS triggers the dock), and stays revealed while the cursor
    /// remains within the dock strip — so it doesn't drop while the user mouses over dock icons.
    private func updateDockRevealed(on screen: NSScreen) -> Bool {
        // A pinned dock is handled purely by `visibleFrame`; reveal tracking is irrelevant.
        // A side dock never overlaps the bottom, so never push the pill up.
        guard dockOrientationIsBottom, screen.visibleFrame.minY <= screen.frame.minY else {
            dockRevealed = false
            return false
        }

        let mouse = NSEvent.mouseLocation
        let onThisScreenHorizontally = mouse.x >= screen.frame.minX && mouse.x <= screen.frame.maxX
        guard onThisScreenHorizontally else {
            dockRevealed = false
            return false
        }

        let edgeBand = screen.frame.minY + 2            // crossing the very bottom edge reveals
        let stayBand = screen.frame.minY + revealedDockHeight + 8  // stay revealed over the strip

        if dockRevealed {
            dockRevealed = mouse.y <= stayBand
        } else {
            dockRevealed = mouse.y <= edgeBand
        }
        return dockRevealed
    }

    // MARK: - Show / hide

    func show(contentSize: NSSize? = nil) {
        let size = contentSize ?? frame.size
        lastContentSize = size
        refreshDockPrefs()
        if let screen = MiniRecorderPanel.targetScreen {
            _ = updateDockRevealed(on: screen)
        }
        setFrame(metrics(contentSize: size), display: true)
        orderFrontRegardless()
        startDockTracking()
    }

    func updateContentSize(_ contentSize: NSSize) {
        lastContentSize = contentSize
        setFrame(metrics(contentSize: contentSize), display: true)
    }

    func hide(completion: @escaping () -> Void) {
        stopDockTracking()
        completion()
    }

    override func orderOut(_ sender: Any?) {
        stopDockTracking()
        super.orderOut(sender)
    }

    // MARK: - Dock tracking

    private func startDockTracking() {
        stopDockTracking()
        lastAppliedRevealed = nil  // force the first tick to evaluate
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.repositionForCurrentDockState()
        }
        // .common mode keeps the timer firing during menu/tracking runloop modes.
        RunLoop.main.add(timer, forMode: .common)
        dockTrackingTimer = timer
    }

    private func stopDockTracking() {
        dockTrackingTimer?.invalidate()
        dockTrackingTimer = nil
    }

    private func repositionForCurrentDockState() {
        guard isVisible, let screen = MiniRecorderPanel.targetScreen else { return }

        let revealed = updateDockRevealed(on: screen)

        // Only act on an actual reveal-state transition. We deliberately do NOT compare against the
        // live `frame` here: while an `animator().setFrame` slide is in flight, `frame` can report
        // the interpolated value, which would make a drift check re-fire every tick and chop the
        // smooth slide into 100ms steps. Screen changes are handled by handleScreenParametersChange
        // and content-size changes by updateContentSize, so the timer's only job is this transition.
        guard lastAppliedRevealed != revealed else { return }
        lastAppliedRevealed = revealed

        let size = lastContentSize ?? frame.size
        let target = metrics(contentSize: size)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().setFrame(target, display: true)
        }
    }

    @objc private func handleScreenParametersChange() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.refreshDockPrefs()
            let size = self.lastContentSize ?? self.frame.size
            self.setFrame(self.metrics(contentSize: size), display: true)
        }
    }

    deinit {
        dockTrackingTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }
}
