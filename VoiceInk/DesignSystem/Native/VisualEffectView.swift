import SwiftUI

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let cornerRadius: CGFloat?
    let appearanceName: NSAppearance.Name?
    let borderWidth: CGFloat
    let borderColor: NSColor?

    init(
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode,
        cornerRadius: CGFloat? = nil,
        appearanceName: NSAppearance.Name? = nil,
        borderWidth: CGFloat = 0,
        borderColor: NSColor? = nil
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.cornerRadius = cornerRadius
        self.appearanceName = appearanceName
        self.borderWidth = borderWidth
        self.borderColor = borderColor
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        configure(visualEffectView)
        return visualEffectView
    }

    func updateNSView(_ visualEffectView: NSVisualEffectView, context: Context) {
        configure(visualEffectView)
    }

    private func configure(_ visualEffectView: NSVisualEffectView) {
        if visualEffectView.material != material {
            visualEffectView.material = material
        }
        if visualEffectView.blendingMode != blendingMode {
            visualEffectView.blendingMode = blendingMode
        }
        if visualEffectView.state != .active {
            visualEffectView.state = .active
        }
        visualEffectView.isEmphasized = false
        visualEffectView.appearance = appearanceName.flatMap { NSAppearance(named: $0) }

        guard let cornerRadius else { return }
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = cornerRadius
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.layer?.borderWidth = borderWidth
        visualEffectView.layer?.borderColor = borderColor?.cgColor
    }
}
