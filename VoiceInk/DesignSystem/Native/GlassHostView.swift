import AppKit

/// Liquid Glass backing shared by the mini recorder pill and notification toasts,
/// so every floating surface near the bottom of the screen reads as one material.
@available(macOS 26.0, *)
final class GlassHostView: NSView {
    private let compositorAwakener = NSVisualEffectView()
    private let glassView = NSGlassEffectView()

    /// Dims the glass like the Dock's: matched against the real Dock over gray backgrounds from 14%
    /// to 50% with the system's glass tint setting at its default (within one level of 255 above 30%).
    static let dockMatchedTint = NSColor.black.withAlphaComponent(0.28)

    var cornerRadius: CGFloat {
        didSet {
            compositorAwakener.layer?.cornerRadius = cornerRadius
            glassView.cornerRadius = cornerRadius
        }
    }

    init(
        contentView: NSView,
        cornerRadius: CGFloat,
        style: NSGlassEffectView.Style = .clear,
        tintColor: NSColor? = GlassHostView.dockMatchedTint
    ) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        compositorAwakener.material = .underWindowBackground
        compositorAwakener.blendingMode = .behindWindow
        compositorAwakener.state = .active
        compositorAwakener.isEmphasized = false
        compositorAwakener.alphaValue = 0.01
        compositorAwakener.translatesAutoresizingMaskIntoConstraints = false
        compositorAwakener.wantsLayer = true
        compositorAwakener.layer?.cornerRadius = cornerRadius
        compositorAwakener.layer?.masksToBounds = true

        glassView.style = style
        glassView.cornerRadius = cornerRadius
        glassView.tintColor = tintColor
        glassView.appearance = NSAppearance(named: .darkAqua)
        glassView.translatesAutoresizingMaskIntoConstraints = false

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor

        addSubview(compositorAwakener)
        addSubview(glassView)
        glassView.contentView = contentView

        NSLayoutConstraint.activate([
            compositorAwakener.leadingAnchor.constraint(equalTo: leadingAnchor),
            compositorAwakener.trailingAnchor.constraint(equalTo: trailingAnchor),
            compositorAwakener.topAnchor.constraint(equalTo: topAnchor),
            compositorAwakener.bottomAnchor.constraint(equalTo: bottomAnchor),

            glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: glassView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: glassView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: glassView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: glassView.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
