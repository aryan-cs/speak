import FluidAudio
import Foundation
import os

/// Whisper models learned from video subtitles, so over silence they often write a stock line such
/// as "Thank you." or a lone period: as the whole transcript of an empty recording, or tacked onto
/// the end of a long one. Speak drops such a line when its speech detector heard no speech while
/// it was supposedly said, and keeps it whenever the detector heard real speech.
enum SilenceHallucinationGuard {
    /// Silero rates clear speech 0.95–1.0. The stock lines Whisper wrote over silence in real
    /// recordings peaked between 0.47 and 0.80.
    static let confidentSpeechProbability: Float = 0.9

    /// Lines Whisper writes over silence, in `normalized` form. Quiet real speech can also score
    /// low, so only these lines are ever dropped, never other words.
    static let silencePhrases: Set<String> = [
        // English
        "thank you", "thank you very much", "thank you so much", "thanks", "thank you bye",
        "thanks for watching", "thank you for watching", "thank you so much for watching",
        "thanks for listening", "thank you for listening", "see you next time",
        "i ll see you next time", "see you in the next video", "please subscribe",
        "like and subscribe", "please like and subscribe", "you", "bye", "bye bye",
        // Other languages, for recordings transcribed with automatic language detection
        "sous titres réalisés par la communauté d amara org", "sous titrage société radio canada",
        "merci d avoir regardé", "merci", "untertitel der amara org community",
        "untertitel im auftrag des zdf", "vielen dank", "danke", "gracias", "gracias por ver",
        "gracias por ver el video", "obrigado", "obrigada", "grazie", "продолжение следует",
        "спасибо", "спасибо за просмотр", "ご視聴ありがとうございました", "ありがとうございました",
        "시청해주셔서 감사합니다", "감사합니다", "字幕由amara org社区提供", "谢谢观看", "謝謝觀看",
    ]

    private static let logger = Logger(subsystem: AppConstants.logSubsystem, category: "SilenceHallucinationGuard")

    // MARK: Whole transcripts

    static func filter(_ text: String, audioURL: URL) async -> String {
        if hasNoWords(text) { return "" }
        guard isSilencePhrase(text), UserDefaults.standard.bool(forKey: "IsVADEnabled") else { return text }
        guard let peak = await SpeechPresenceDetector.shared.peakSpeechProbability(in: audioURL) else { return text }
        let filtered = filter(text, peakSpeechProbability: peak)
        if filtered.isEmpty {
            logger.notice("Dropped a stock line written over silence; peak speech probability \(peak, privacy: .public)")
        }
        return filtered
    }

    static func filter(_ text: String, peakSpeechProbability: Float) -> String {
        if hasNoWords(text) { return "" }
        return isSilencePhrase(text) && peakSpeechProbability < confidentSpeechProbability ? "" : text
    }

    // MARK: Timed transcripts

    /// Drops lines Whisper wrote over the silent parts of a recording, such as a "Thank you."
    /// after the last real sentence, using each line's time span from the provider.
    static func removingSilenceLines(from transcript: SegmentedTranscript, audioURL: URL) async -> String {
        guard let segments = transcript.segments,
            segments.contains(where: { isSilencePhrase($0.text) }),
            UserDefaults.standard.bool(forKey: "IsVADEnabled"),
            let probabilities = await SpeechPresenceDetector.shared.frameProbabilities(in: audioURL)
        else { return transcript.text }

        let dropped = droppedSegments(segments, frameProbabilities: probabilities)
        guard !dropped.isEmpty else { return transcript.text }
        logger.notice(
            "Dropped \(dropped.count, privacy: .public) of \(segments.count, privacy: .public) lines written over silence"
        )
        return text(of: transcript, dropping: dropped)
    }

    /// Indices of stock lines during which the detector heard no speech.
    static func droppedSegments(_ segments: [SegmentedTranscript.Segment], frameProbabilities: [Float]) -> IndexSet {
        IndexSet(
            segments.indices.filter { index in
                let segment = segments[index]
                guard isSilencePhrase(segment.text) else { return false }
                let peak = peakProbability(from: segment.start, to: segment.end, in: frameProbabilities)
                logger.notice(
                    "Stock line at \(segment.start, privacy: .public)–\(segment.end, privacy: .public)s; peak speech probability \(peak, privacy: .public)"
                )
                return peak < confidentSpeechProbability
            })
    }

    /// Whisper's segment times are loose by a fraction of a second, so a line over trailing
    /// silence can start inside the last real word. The first quarter second is not counted.
    static func peakProbability(from start: TimeInterval, to end: TimeInterval, in frameProbabilities: [Float])
        -> Float
    {
        let frameSeconds = Double(VadManager.chunkSize) / Double(VadManager.sampleRate)
        let windowStart = min(start + 0.25, (start + end) / 2)
        let windowEnd = max(end, windowStart)
        let first = max(0, Int(windowStart / frameSeconds))
        let last = min(frameProbabilities.count - 1, Int(windowEnd / frameSeconds))
        guard first <= last else { return 0 }
        return frameProbabilities[first...last].max() ?? 0
    }

    /// The provider's text without the dropped lines. Whisper's text is its segments joined, so
    /// the kept segments rebuild it; if they don't match, only dropped lines at its ends are cut.
    static func text(of transcript: SegmentedTranscript, dropping dropped: IndexSet) -> String {
        func collapsed(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let segments = transcript.segments ?? []
        if collapsed(segments.map(\.text).joined(separator: " ")) == collapsed(transcript.text) {
            let kept = segments.indices.filter { !dropped.contains($0) }.map { segments[$0].text }
            return collapsed(kept.joined(separator: " "))
        }

        var text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var last = segments.endIndex
        while last > segments.startIndex, dropped.contains(last - 1) {
            last -= 1
            let line = segments[last].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasSuffix(line) else { return transcript.text }
            text = String(text.dropLast(line.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var first = segments.startIndex
        while first < last, dropped.contains(first) {
            let line = segments[first].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix(line) else { return transcript.text }
            text = String(text.dropFirst(line.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            first += 1
        }
        return text
    }

    // MARK: Matching

    /// True for text such as "." or "...", which no one dictates.
    static func hasNoWords(_ text: String) -> Bool {
        !text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// True when every sentence is a stock silence line, e.g. "Thank you." or "Thank you. Bye."
    static func isSilencePhrase(_ text: String) -> Bool {
        let sentences = sentences(in: text).map(normalized).filter { !$0.isEmpty }
        return !sentences.isEmpty && sentences.allSatisfy(silencePhrases.contains)
    }

    /// Lowercase words separated by single spaces, with punctuation dropped.
    static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Splits at sentence-ending punctuation followed by a space or the end, so "Amara.org" stays whole.
    private static func sentences(in text: String) -> [String] {
        text.replacingOccurrences(of: #"[.!?…]+(\s|$)|[。！？]+|\n"#, with: "\u{0}", options: .regularExpression)
            .components(separatedBy: "\u{0}")
    }
}

/// Speak's speech detector (Silero VAD), loaded on first use.
actor SpeechPresenceDetector {
    static let shared = SpeechPresenceDetector()

    private var manager: VadManager?
    private let logger = Logger(subsystem: AppConstants.logSubsystem, category: "SpeechPresenceDetector")

    /// The highest speech probability anywhere in the recording, or nil when detection fails.
    func peakSpeechProbability(in audioURL: URL) async -> Float? {
        guard let probabilities = await frameProbabilities(in: audioURL) else { return nil }
        return probabilities.max() ?? 0
    }

    /// Speech probability for each 256 ms of the recording, or nil when detection fails.
    func frameProbabilities(in audioURL: URL) async -> [Float]? {
        do {
            let samples = try AudioConverter().resampleAudioFile(audioURL)
            guard !samples.isEmpty else { return [] }
            let manager = try await loadedManager()
            return try await manager.process(samples).map(\.probability)
        } catch {
            logger.notice("Speech detection failed; keeping the transcript: \(error, privacy: .public)")
            return nil
        }
    }

    private func loadedManager() async throws -> VadManager {
        if let manager { return manager }
        let loaded = try await VadManager(config: VadConfig(defaultThreshold: 0.7))
        manager = loaded
        return loaded
    }
}
