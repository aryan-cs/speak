import SwiftUI

struct AppNotificationView: View {
    let title: String
    let type: NotificationType
    let duration: TimeInterval
    let onClose: () -> Void
    let onTap: (() -> Void)?
    /// Shown as an icon in the pill's round control style; the label is its tooltip.
    var actionButton: (label: String, systemImage: String, action: () -> Void)? = nil
    /// When true the hosting panel supplies the Liquid Glass background (macOS 26+), matching the recorder pill.
    var usesExternalGlass: Bool = false

    enum NotificationType {
        case error
        case warning
        case info
        case success
    }

    /// Styled like the Dock's hover labels: a slim capsule with 14 pt regular text.
    static let defaultHeight: CGFloat = 22
    var height: CGFloat = Self.defaultHeight
    /// The pill's 21 pt controls, scaled down for shorter capsules.
    private var controlSize: CGFloat { min(21, height - 6) }
    /// Gap between the text and the capsule's end.
    private var textInset: CGFloat { 14 }

    // Capsule, like the recorder pill it sits above.
    private var shape: Capsule {
        Capsule(style: .continuous)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            if let actionButton {
                Button(action: {
                    actionButton.action()
                    onClose()
                }) {
                    // Just the icon, in the label's color, like the Dock's plain controls.
                    Image(systemName: actionButton.systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: controlSize, height: controlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(actionButton.label)
                .accessibilityLabel(actionButton.label)
            }
        }
        // The capsule hugs its text; an action button sits concentric with its rounded end, with as
        // much space to its right as above and below it.
        .padding(.leading, textInset)
        .padding(.trailing, actionButton == nil ? textInset : (height - controlSize) / 2)
        .frame(maxWidth: 750, minHeight: height)
        .background {
            // Before Liquid Glass, a dark surface stands in for the pill's glass.
            if !usesExternalGlass {
                ZStack {
                    Color.black.opacity(0.9)
                    VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                        .opacity(0.05)
                }
                .clipShape(shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
            }
        }
        .contentShape(shape)
        // With no close button, a tap dismisses the pill.
        .onTapGesture {
            onTap?()
            onClose()
        }
    }
}
