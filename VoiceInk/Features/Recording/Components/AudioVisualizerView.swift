import SwiftUI

struct AudioVisualizer: View {
    let audioMeterProvider: () -> AudioMeter
    let color: Color
    let isActive: Bool

    // Frequency bands mirrored around the center: lowest band in the middle, highest at both edges.
    private let barCount = SpectrumAnalyzer.bandCount * 2 - 1
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2
    private let minHeight: CGFloat = 4
    private let maxHeight: CGFloat = 28

    init(audioMeterProvider: @escaping () -> AudioMeter, color: Color, isActive: Bool) {
        self.audioMeterProvider = audioMeterProvider
        self.color = color
        self.isActive = isActive
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.016)) { _ in
            let audioMeter = audioMeterProvider()

            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(color.opacity(0.85))
                        .frame(width: barWidth, height: barHeight(for: index, audioMeter: audioMeter))
                }
            }
        }
    }

    private func barHeight(for index: Int, audioMeter: AudioMeter) -> CGFloat {
        guard isActive else { return minHeight }

        let bands = audioMeter.bands
        let level: Double
        if bands.isEmpty {
            level = audioMeter.averagePower
        } else {
            let distanceFromCenter = abs(index - barCount / 2)
            level = bands[min(distanceFromCenter, bands.count - 1)]
        }

        return minHeight + CGFloat(max(0, min(1, level))) * (maxHeight - minHeight)
    }
}

// Flat bars shown when the recorder is idle (no audio input)
struct StaticVisualizer: View {
    private let barCount = 15
    private let barWidth: CGFloat = 3
    private let barHeight: CGFloat = 4
    private let barSpacing: CGFloat = 2
    let color: Color

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { _ in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(color.opacity(0.5))
                    .frame(width: barWidth, height: barHeight)
            }
        }
    }
}

// MARK: - Processing Status Display

struct ProcessingStatusDisplay: View {
    enum Mode {
        case transcribing
        case enhancing
    }

    let mode: Mode
    let color: Color

    private var animationSpeed: Double {
        switch mode {
        case .transcribing: return 0.18
        case .enhancing: return 0.22
        }
    }

    var body: some View {
        ProgressAnimation(color: color, animationSpeed: animationSpeed)
        .frame(height: 28) // matches AudioVisualizer maxHeight to prevent layout shift
    }
}
