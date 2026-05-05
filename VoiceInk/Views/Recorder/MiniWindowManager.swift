import SwiftUI
import AppKit

@MainActor
class MiniWindowManager: ObservableObject {
    @Published var isVisible = false
    private var windowController: NSWindowController?
    private var panel: MiniRecorderPanel?
    private weak var glassView: NSView?
    private var contentSize = NSSize(width: 112, height: 40)

    private let makeView: (MiniWindowManager) -> AnyView

    init(engine: VoiceInkEngine, recorder: Recorder) {
        guard let enhancementService = engine.enhancementService else {
            preconditionFailure("VoiceInkEngine.enhancementService must be non-nil when creating MiniWindowManager")
        }
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
                    usesExternalGlass: usesExternalGlass
                )
                    .environmentObject(manager)
                    .environmentObject(enhancementService)
            )
        }
        setupNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleHideNotification),
            name: NSNotification.Name("HideMiniRecorder"),
            object: nil
        )
    }

    @objc private func handleHideNotification() {
        hide()
    }

    func show() {
        if isVisible { return }
        if panel == nil { initializeWindow() }
        isVisible = true
        panel?.show(contentSize: contentSize)
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        panel?.orderOut(nil)
    }

    func destroyWindow() {
        isVisible = false
        deinitializeWindow()
    }

    private func initializeWindow() {
        deinitializeWindow()
        let metrics = MiniRecorderPanel.calculateWindowMetrics(contentSize: contentSize)
        let newPanel = MiniRecorderPanel(contentRect: metrics)
        let view = makeView(self)
        let hostingController = NSHostingController(rootView: view)

        if #available(macOS 26.0, *) {
            newPanel.contentView = makeGlassHost(
                contentView: hostingController.view,
                cornerRadius: contentSize.height / 2
            )
        } else {
            newPanel.contentView = hostingController.view
        }

        panel = newPanel
        windowController = NSWindowController(window: newPanel)
    }

    private func deinitializeWindow() {
        panel?.orderOut(nil)
        windowController?.close()
        windowController = nil
        panel = nil
        glassView = nil
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func updateContentMetrics(width: CGFloat, height: CGFloat, cornerRadius: CGFloat) {
        let nextSize = NSSize(width: width, height: height)
        if contentSize != nextSize {
            contentSize = nextSize
            panel?.updateContentSize(nextSize)
        }

        if #available(macOS 26.0, *) {
            (glassView as? NSGlassEffectView)?.cornerRadius = cornerRadius
        }
    }

    @available(macOS 26.0, *)
    private func makeGlassHost(contentView: NSView, cornerRadius: CGFloat) -> NSView {
        let rootView = NSView()
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor

        let compositorAwakener = NSVisualEffectView()
        compositorAwakener.material = .underWindowBackground
        compositorAwakener.blendingMode = .behindWindow
        compositorAwakener.state = .active
        compositorAwakener.isEmphasized = false
        compositorAwakener.alphaValue = 0.01
        compositorAwakener.translatesAutoresizingMaskIntoConstraints = false
        compositorAwakener.wantsLayer = true
        compositorAwakener.layer?.cornerRadius = cornerRadius
        compositorAwakener.layer?.masksToBounds = true

        let glassView = NSGlassEffectView()
        glassView.style = .clear
        glassView.cornerRadius = cornerRadius
        glassView.tintColor = nil
        glassView.appearance = NSAppearance(named: .darkAqua)
        glassView.translatesAutoresizingMaskIntoConstraints = false

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor

        rootView.addSubview(compositorAwakener)
        rootView.addSubview(glassView)
        glassView.contentView = contentView

        NSLayoutConstraint.activate([
            compositorAwakener.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            compositorAwakener.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            compositorAwakener.topAnchor.constraint(equalTo: rootView.topAnchor),
            compositorAwakener.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            glassView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            glassView.topAnchor.constraint(equalTo: rootView.topAnchor),
            glassView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: glassView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: glassView.bottomAnchor)
        ])

        self.glassView = glassView
        return rootView
    }
}
