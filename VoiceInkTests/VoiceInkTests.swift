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
}
