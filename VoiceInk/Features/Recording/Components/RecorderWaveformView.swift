import SwiftUI

/// How the recorder draws your voice while recording.
enum RecorderWaveformStyle: String, CaseIterable, Identifiable {
    /// 15 bars, one per frequency band.
    case classic
    /// 25 hairline bars under a bell-shaped silhouette that tapers to dots at the ends.
    case fineBars
    /// A line of light that parts into a lens.
    case glowLine
    /// Seven capsules, like the waveform symbol.
    case glyph

    static let userDefaultsKey = "RecorderWaveformStyle"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic: return String(localized: "Classic")
        case .fineBars: return String(localized: "Fine Bars")
        case .glowLine: return String(localized: "Glow Line")
        case .glyph: return String(localized: "Glyph")
        }
    }
}

/// The waveform styles driven by overall loudness rather than per-band levels. One smoothed
/// signal scales a fixed, symmetric shape, and every element follows it on its own spring, so the
/// motion stays smooth at any frame rate.
struct LoudnessWaveform: View {
    let style: RecorderWaveformStyle
    let audioMeterProvider: () -> AudioMeter
    let isActive: Bool
    /// Tallest the waveform gets.
    let maxHeight: CGFloat

    @StateObject private var motion = WaveformMotion()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Room around the glow line for its blur.
    private static let glowPadding: CGFloat = 6

    var body: some View {
        // Outside recording it draws its resting shape once.
        TimelineView(.animation(paused: !isActive)) { timeline in
            Canvas { context, size in
                motion.advance(
                    to: timeline.date,
                    loudnessDb: isActive ? audioMeterProvider().loudnessDb : nil,
                    reduceMotion: reduceMotion
                )
                switch style {
                case .fineBars: drawFineBars(in: &context, size: size)
                case .glyph: drawGlyph(in: &context, size: size)
                case .glowLine: drawGlowLine(in: &context, size: size)
                case .classic: break
                }
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .allowsHitTesting(false)
    }

    private var canvasSize: CGSize {
        switch style {
        case .fineBars: return CGSize(width: FineBars.width, height: maxHeight)
        case .glyph: return CGSize(width: Glyph.width, height: maxHeight)
        case .glowLine, .classic:
            return CGSize(width: GlowLine.width + 2 * Self.glowPadding, height: maxHeight + 2 * Self.glowPadding)
        }
    }

    // MARK: Fine bars

    private enum FineBars {
        static let count = 25
        static let barWidth: CGFloat = 1.5
        static let spacing: CGFloat = 1.5
        static let width = CGFloat(count) * barWidth + CGFloat(count - 1) * spacing

        /// Position of each bar from the center, -1 (left end) to 1 (right end).
        static let positions: [Double] = (0..<count).map { Double($0 - count / 2) / Double(count / 2) }
        /// How tall each bar may get: a raised cosine, full height in the middle and none at
        /// either end, where the bars stay dots.
        static let envelope: [Double] = positions.map { pow(cos($0 * .pi / 2), 2) }
        /// How much voice each bar needs: the level is raised to a higher power away from the
        /// middle, so quiet speech lifts only the center and louder speech spreads outward.
        static let reachExponent: [Double] = positions.map { 1 + 1.8 * $0 * $0 }
    }

    private func drawFineBars(in context: inout GraphicsContext, size: CGSize) {
        let heights = motion.springValues(count: FineBars.count) { index in
            let envelope = FineBars.envelope[index]
            let idle = 0.05 * motion.breath * envelope
            let voiced = pow(motion.level, FineBars.reachExponent[index]) * envelope
                * (0.7 + 0.3 * motion.wobble(index: abs(index - FineBars.count / 2)))
            // Quick and slightly springy, so the bars follow inflection.
            return (max(idle, voiced), 0.09)
        } damping: { _ in 0.8 }
        for index in 0..<FineBars.count {
            let height = FineBars.barWidth + (maxHeight - FineBars.barWidth) * CGFloat(min(1, max(0, heights[index])))
            let x = CGFloat(index) * (FineBars.barWidth + FineBars.spacing)
            let rect = CGRect(x: x, y: (size.height - height) / 2, width: FineBars.barWidth, height: height)
            let opacity = 0.45 + 0.5 * FineBars.envelope[index]
            context.fill(Capsule().path(in: rect), with: .color(.white.opacity(opacity)))
        }
    }

    // MARK: Glyph

    private enum Glyph {
        static let profile: [Double] = [0.45, 0.68, 0.88, 1, 0.88, 0.68, 0.45]
        /// The center bar answers first and the outer bars later, so each syllable ripples outward.
        static let response: [Double] = [0.28, 0.21, 0.16, 0.12, 0.16, 0.21, 0.28]
        static let barWidth: CGFloat = 3
        static let spacing: CGFloat = 3
        static let width = CGFloat(profile.count) * barWidth + CGFloat(profile.count - 1) * spacing
    }

    private func drawGlyph(in context: inout GraphicsContext, size: CGSize) {
        let middle = Glyph.profile.count / 2
        let heights = motion.springValues(count: Glyph.profile.count) { index in
            let profile = Glyph.profile[index]
            let idle = 0.05 + 0.04 * motion.breath * profile
            let voiced = motion.level * profile * (0.86 + 0.14 * motion.wobble(index: abs(index - middle)))
            return (max(idle, voiced), Glyph.response[index])
        }
        for index in 0..<Glyph.profile.count {
            let height = Glyph.barWidth + (maxHeight - Glyph.barWidth) * CGFloat(min(1, max(0, heights[index])))
            let x = CGFloat(index) * (Glyph.barWidth + Glyph.spacing)
            let rect = CGRect(x: x, y: (size.height - height) / 2, width: Glyph.barWidth, height: height)
            let opacity = 0.92 - 0.08 * Double(abs(index - middle))
            context.fill(Capsule().path(in: rect), with: .color(.white.opacity(opacity)))
        }
    }

    // MARK: Glow line

    private enum GlowLine {
        static let width: CGFloat = 80
        static let samples = 96

        /// Lens shape across x in -2...2: full in the middle, pinched to nothing at both ends.
        static func lens(_ x: Double) -> Double { pow(2 / (2 + pow(x, 4)), 2) }
    }

    private func drawGlowLine(in context: inout GraphicsContext, size: CGSize) {
        let opening = motion.springValues(count: 1) { _ in (motion.level, 0.15) }[0]
        let halfHeight = Double(maxHeight / 2 - 1.5) * max(0, opening)
        let originX = Self.glowPadding
        let midY = size.height / 2
        let time = motion.time

        func offset(at u: Double) -> CGFloat {
            let x = u * 4 - 2
            let ripple = reduceMotion ? 1 : 1 + 0.1 * cos(6 * x) * sin(time * 1.7)
            return CGFloat(halfHeight * GlowLine.lens(x) * ripple)
        }
        func contour(_ sign: CGFloat) -> Path {
            var path = Path()
            for step in 0...GlowLine.samples {
                let u = Double(step) / Double(GlowLine.samples)
                let point = CGPoint(x: originX + CGFloat(u) * GlowLine.width, y: midY + sign * offset(at: u))
                step == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            return path
        }
        var lens = contour(-1)
        for step in stride(from: GlowLine.samples, through: 0, by: -1) {
            let u = Double(step) / Double(GlowLine.samples)
            lens.addLine(to: CGPoint(x: originX + CGFloat(u) * GlowLine.width, y: midY + offset(at: u)))
        }
        lens.closeSubpath()

        let fade = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [
                .init(color: .white.opacity(0), location: 0),
                .init(color: .white.opacity(0.7), location: 0.2),
                .init(color: .white, location: 0.5),
                .init(color: .white.opacity(0.7), location: 0.8),
                .init(color: .white.opacity(0), location: 1),
            ]),
            startPoint: CGPoint(x: originX, y: midY),
            endPoint: CGPoint(x: originX + GlowLine.width, y: midY)
        )
        let edges = [contour(-1), contour(1)]
        let stroke = StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)

        context.blendMode = .plusLighter
        // Soft glow behind the contours.
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 2 + 3 * motion.level + 0.5 * motion.breath))
            glow.opacity = 0.8
            for edge in edges { glow.stroke(edge, with: fade, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)) }
        }
        // Faint light between the contours, then the contours themselves.
        var fill = context
        fill.opacity = 0.14 + 0.1 * motion.level
        fill.fill(lens, with: fade)
        context.opacity = 0.9
        for edge in edges { context.stroke(edge, with: fade, style: stroke) }
    }
}

/// Loudness envelope and spring state for `LoudnessWaveform`, advanced once per frame.
final class WaveformMotion: ObservableObject {
    /// Voice level, 0...1: a fast envelope of loudness, pushed up at the start of each syllable.
    private(set) var level: Double = 0
    private var envelope: Double = 0
    /// The envelope over the last half second or so, to tell a syllable's onset from a held sound.
    private var slowEnvelope: Double = 0
    /// Seconds since the waveform first drew, for slow ambient motion.
    private(set) var time: TimeInterval = 0
    /// Slow breathing, 0...1, so the waveform is never dead while you are silent.
    private(set) var breath: Double = 0

    private var lastDate: Date?
    private var delta: TimeInterval = 0
    private var reduceMotion = false
    private var springs: [Spring] = []

    private struct Spring {
        var value = 0.0
        var velocity = 0.0

        /// Damping 1 is critical (no overshoot); lower values overshoot slightly. Integrated in
        /// small steps so it is stable at any frame rate.
        mutating func step(toward target: Double, over seconds: TimeInterval, response: Double, damping: Double) {
            let omega = 2 * Double.pi / response
            let steps = max(1, Int((seconds * 480).rounded(.up)))
            let h = seconds / Double(steps)
            for _ in 0..<steps {
                let acceleration = omega * omega * (target - value) - 2 * damping * omega * velocity
                velocity += acceleration * h
                value += velocity * h
            }
        }
    }

    /// Maps loudness to 0...1: -52 dBFS (room noise) is silence and -28 dBFS is loud speech. The
    /// square widens the gap between quiet and loud words, so inflection shows. Measured on real
    /// dictations, the middle bar spans about 25–95% of its height, against 43–90% with a linear,
    /// soft-topped curve.
    static func level(forLoudnessDb db: Double) -> Double {
        let t = min(1, max(0, (db + 52) / 24))
        return t * t
    }

    /// Moves time forward to `date`; `loudnessDb` is nil while not recording.
    func advance(to date: Date, loudnessDb: Double?, reduceMotion: Bool) {
        let seconds = lastDate.map { min(0.05, max(0, date.timeIntervalSince($0))) } ?? 0
        lastDate = date
        delta = seconds
        time += seconds
        self.reduceMotion = reduceMotion
        breath = reduceMotion ? 0 : 0.5 + 0.5 * sin(2 * .pi * time / 2.6)

        // Rises in 20 ms and falls in 110 ms, so the gaps between words show.
        let target = loudnessDb.map(Self.level(forLoudnessDb:)) ?? 0
        let timeConstant = target > envelope ? 0.02 : 0.11
        envelope += (target - envelope) * (1 - exp(-seconds / timeConstant))
        slowEnvelope += (target - slowEnvelope) * (1 - exp(-seconds / 0.4))
        level = min(1, envelope + 0.6 * max(0, envelope - slowEnvelope))
    }

    /// Slow organic variation per element, 0...1.
    func wobble(index: Int) -> Double {
        guard !reduceMotion else { return 0.5 }
        let i = Double(index)
        return 0.5 + 0.25 * sin(time * 1.9 + i * 2.17) + 0.25 * sin(time * 3.1 + i * 1.31)
    }

    /// Steps one spring per element toward the `(target, response)` the closure gives it.
    func springValues(
        count: Int, target: (Int) -> (Double, Double), damping: (Int) -> Double = { _ in 1 }
    ) -> [Double] {
        if springs.count != count { springs = Array(repeating: Spring(), count: count) }
        return (0..<count).map { index in
            let (value, response) = target(index)
            springs[index].step(toward: value, over: delta, response: response, damping: damping(index))
            return springs[index].value
        }
    }
}
