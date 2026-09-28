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

    /// A slimmer capsule than the 40 pt recorder pill, in the same glass and controls.
    static let defaultHeight: CGFloat = 30
    var height: CGFloat = Self.defaultHeight
    /// The pill's 21 pt controls, scaled down for shorter capsules.
    private var controlSize: CGFloat { min(21, height - 8) }
    /// Gap between the controls and the capsule's end, repeated between the controls.
    private var controlInset: CGFloat { max(4, (height - controlSize) / 2) }

    // Capsule, like the recorder pill it sits above.
    private var shape: Capsule {
        Capsule(style: .continuous)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)

            HStack(spacing: controlInset) {
                if let actionButton {
                    Button(action: {
                        actionButton.action()
                        onClose()
                    }) {
                        // The recorder pill's control style.
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.13))
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
                                )

                            Image(systemName: actionButton.systemImage)
                                .font(.system(size: controlSize * 0.43, weight: .semibold))
                                .foregroundColor(.white.opacity(0.86))
                        }
                        .frame(width: controlSize, height: controlSize)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(actionButton.label)
                    .accessibilityLabel(actionButton.label)
                }

                RecorderCloseButton(action: onClose)
                    .scaleEffect(controlSize / 21)
                    .frame(width: controlSize, height: controlSize)
            }
        }
        // Controls sit concentric with the capsule's end.
        .padding(.leading, max(12, height * 0.45))
        .padding(.trailing, controlInset)
        .frame(minWidth: 180, maxWidth: 750, minHeight: height)
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
        .onTapGesture {
            if let onTap = onTap {
                onTap()
                onClose()
            }
        }
    }
}
