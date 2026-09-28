//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Testing
@testable import VoiceInk

struct VoiceInkTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    @Test func silentTranscriptionDoesNotPaste() {
        #expect(!TranscriptionPastePolicy.shouldPaste(nil))
        #expect(!TranscriptionPastePolicy.shouldPaste(""))
        #expect(!TranscriptionPastePolicy.shouldPaste(" \t\n"))
        #expect(!TranscriptionPastePolicy.shouldPaste("\u{00A0}"))
        #expect(TranscriptionPastePolicy.shouldPaste("hello"))
        #expect(TranscriptionPastePolicy.shouldPaste(" hello "))
    }

    @Test func audioDuckingProfilesPreferCallsOverMusic() {
        #expect(
            AudioDuckingPolicy.profile(for: ["com.spotify.client"]) == .music
        )
        #expect(
            AudioDuckingPolicy.profile(for: ["com.microsoft.teams2"]) == .communication
        )
        #expect(
            AudioDuckingPolicy.profile(
                for: ["com.spotify.client", "com.microsoft.teams2.helper"]
            ) == .communication
        )
        #expect(
            AudioDuckingPolicy.profile(for: ["com.example.player"]) == .standard
        )
    }

    @Test func audioDuckingProfilesUseConfiguredStaticLevels() {
        #expect(
            AudioDuckingPolicy.level(
                for: .music,
                standardLevel: 0.2,
                musicLevel: 0.15,
                communicationLevel: 0.3
            ) == 0.15
        )
        #expect(
            AudioDuckingPolicy.level(
                for: .standard,
                standardLevel: 0.2,
                musicLevel: 0.15,
                communicationLevel: 0.3
            ) == 0.2
        )
        #expect(
            AudioDuckingPolicy.level(
                for: .communication,
                standardLevel: 0.2,
                musicLevel: 0.15,
                communicationLevel: 0.3
            ) == 0.3
        )
    }

    @Test func spectrumAnalyzerLightsTheBandContainingATone() throws {
        let sampleRate = 48_000.0
        let analyzer = try #require(SpectrumAnalyzer(sampleRate: sampleRate))
        // 0.3 s of a 1 kHz tone at -12 dBFS, fed in 10 ms callbacks like the audio unit does.
        let chunk = 480
        var phase = 0.0
        var buffer = [Float](repeating: 0, count: chunk)
        for _ in 0..<30 {
            for index in 0..<chunk {
                buffer[index] = Float(0.25 * sin(phase))
                phase += 2 * .pi * 1_000 / sampleRate
            }
            buffer.withUnsafeBufferPointer { analyzer.process($0.baseAddress!, frameCount: chunk, channelCount: 1) }
        }
        let loudest = try #require(analyzer.levels.indices.max { analyzer.levels[$0] < analyzer.levels[$1] })
        // Bands are log-spaced 80 Hz–8 kHz, so 1 kHz falls in band 4 (800–1423 Hz).
        #expect(loudest == 4)
        #expect(analyzer.levels[4] > 0.9)
        #expect(analyzer.levels[0] < 0.2)
    }

    @Test func spectrumAnalyzerStaysFlatInSilence() throws {
        let analyzer = try #require(SpectrumAnalyzer(sampleRate: 16_000))
        let silence = [Float](repeating: 0, count: 160)
        for _ in 0..<20 {
            silence.withUnsafeBufferPointer { analyzer.process($0.baseAddress!, frameCount: 160, channelCount: 1) }
        }
        #expect(analyzer.levels.allSatisfy { $0 == 0 })
    }
}
