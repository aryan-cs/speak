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
}
