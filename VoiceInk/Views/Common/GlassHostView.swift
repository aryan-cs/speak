import AppKit

/// Liquid Glass backing shared by the mini recorder pill and notification toasts,
/// so every floating surface near the bottom of the screen reads as one material.
@available(macOS 26.0, *)
final class GlassHostView: NSView {
    private let compositorAwakener = NSVisualEffectView()
    private let glassView = NSGlassEffectView()
    private let edgeHighlightView: GlassEdgeHighlightView

    var cornerRadius: CGFloat {
        didSet {
            compositorAwakener.layer?.cornerRadius = cornerRadius
            glassView.cornerRadius = cornerRadius
            edgeHighlightView.cornerRadius = cornerRadius
        }
    }

    init(
        contentView: NSView,
        cornerRadius: CGFloat,
        style: NSGlassEffectView.Style = .clear,
        tintColor: NSColor? = nil
    ) {
        self.cornerRadius = cornerRadius
        self.edgeHighlightView = GlassEdgeHighlightView(cornerRadius: cornerRadius)
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

        edgeHighlightView.translatesAutoresizingMaskIntoConstraints = false

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor

        addSubview(compositorAwakener)
        addSubview(glassView)
        addSubview(edgeHighlightView)
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

            edgeHighlightView.leadingAnchor.constraint(equalTo: leadingAnchor),
            edgeHighlightView.trailingAnchor.constraint(equalTo: trailingAnchor),
            edgeHighlightView.topAnchor.constraint(equalTo: topAnchor),
            edgeHighlightView.bottomAnchor.constraint(equalTo: bottomAnchor),

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

private final class GlassEdgeHighlightView: NSView {
    var cornerRadius: CGFloat {
        didSet {
            needsLayout = true
        }
    }

    private let topLeftHighlight = CAGradientLayer()
    private let bottomRightHighlight = CAGradientLayer()
    private let topLeftMask = CAShapeLayer()
    private let bottomRightMask = CAShapeLayer()

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        self.cornerRadius = 20
        super.init(coder: coder)
        setupLayers()
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let layerBounds = bounds
        topLeftHighlight.frame = layerBounds
        bottomRightHighlight.frame = layerBounds

        let strokeInset: CGFloat = 0.35
        let pathBounds = layerBounds.insetBy(dx: strokeInset, dy: strokeInset)
        let radius = max(0, cornerRadius - strokeInset)
        let path = CGPath(
            roundedRect: pathBounds,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )

        configure(mask: topLeftMask, with: path)
        configure(mask: bottomRightMask, with: path)

        CATransaction.commit()
    }

    private func setupLayers() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        configureTopLeftHighlight()
        configureBottomRightHighlight()

        topLeftHighlight.mask = topLeftMask
        bottomRightHighlight.mask = bottomRightMask

        layer?.addSublayer(topLeftHighlight)
        layer?.addSublayer(bottomRightHighlight)
    }

    private func configureTopLeftHighlight() {
        topLeftHighlight.startPoint = CGPoint(x: 0, y: 0)
        topLeftHighlight.endPoint = CGPoint(x: 1, y: 1)
        topLeftHighlight.locations = [0, 0.28, 0.58, 1]
        topLeftHighlight.colors = [
            NSColor.white.withAlphaComponent(0.30).cgColor,
            NSColor.white.withAlphaComponent(0.13).cgColor,
            NSColor.white.withAlphaComponent(0.03).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor
        ]
    }

    private func configureBottomRightHighlight() {
        bottomRightHighlight.startPoint = CGPoint(x: 1, y: 1)
        bottomRightHighlight.endPoint = CGPoint(x: 0, y: 0)
        bottomRightHighlight.locations = [0, 0.26, 0.56, 1]
        bottomRightHighlight.colors = [
            NSColor.white.withAlphaComponent(0.22).cgColor,
            NSColor.white.withAlphaComponent(0.09).cgColor,
            NSColor.white.withAlphaComponent(0.02).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor
        ]
    }

    private func configure(mask: CAShapeLayer, with path: CGPath) {
        mask.frame = bounds
        mask.path = path
        mask.fillColor = NSColor.clear.cgColor
        mask.strokeColor = NSColor.white.cgColor
        mask.lineWidth = 0.35
        mask.lineJoin = .round
        mask.lineCap = .round
    }
}
