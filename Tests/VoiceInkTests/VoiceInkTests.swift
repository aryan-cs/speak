//
//  VoiceInkTests.swift
//  VoiceInkTests
//
//  Created by Prakash Joshi on 15/10/2024.
//

import Foundation
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

    @Test func autoLearnFindsMisheardProductNames() throws {
        let pasted = "We should ship the whisper flow integration on Friday."
        let snapshot = AutoLearnFieldSnapshot(
            baselineFieldText: "Notes: " + pasted,
            finalFieldText: "Notes: We should ship the Wispr Flow integration on Friday.",
            pastedRange: NSRange(location: 7, length: (pasted as NSString).length),
            originalPastedText: pasted
        )
        let revision = try #require(FinalSnapshotDiffEngine.revision(from: snapshot))
        let candidates = CorrectionDiffEngine.candidates(from: revision)
        #expect(candidates.count == 1)
        #expect(candidates.first?.originalText.contains("whisper flow") == true)
        #expect(candidates.first?.correctedText.contains("Wispr Flow") == true)
    }

    @Test func autoLearnIgnoresUntouchedPastes() {
        let pasted = "Nothing changed here."
        let snapshot = AutoLearnFieldSnapshot(
            baselineFieldText: pasted,
            finalFieldText: pasted,
            pastedRange: NSRange(location: 0, length: (pasted as NSString).length),
            originalPastedText: pasted
        )
        #expect(FinalSnapshotDiffEngine.revision(from: snapshot) == nil)
    }

    @Test func autoLearnRepairsTruncatedReviewerSpans() {
        let original = "Please email prakash joshi packs about the release"
        let corrected = "Please email Prakash Joshi Pax about the release"
        let repaired = CorrectionDiffEngine.repairedReviewSpans(
            incorrectText: "prakash joshi packs",
            correctedTerm: "Prakash Joshi",
            originalText: original,
            correctedText: corrected
        )
        #expect(repaired.incorrectText == "prakash joshi packs")
        #expect(repaired.correctedTerm == "Prakash Joshi Pax")
    }

    @Test func autoLearnRepairsSwappedReviewerSource() {
        let repaired = CorrectionDiffEngine.repairedReviewSpans(
            incorrectText: "Wispr Flow",
            correctedTerm: "Wispr Flow",
            originalText: "should ship the whisper flow integration on Friday",
            correctedText: "should ship the Wispr Flow integration on Friday"
        )
        #expect(repaired.incorrectText == "whisper flow")
        #expect(repaired.correctedTerm == "Wispr Flow")
    }

    @Test func autoLearnKeepsUnchangedNamePartsFromReviewer() {
        let repaired = CorrectionDiffEngine.repairedReviewSpans(
            incorrectText: "Prakash Joshi Pages",
            correctedTerm: "Prakash Joshi Pax",
            originalText: "Prakash Joshi Pages said hi",
            correctedText: "Prakash Joshi Pax said hi"
        )
        #expect(repaired.incorrectText == "Prakash Joshi Pages")
        #expect(repaired.correctedTerm == "Prakash Joshi Pax")
    }

    @Test func autoLearnReviewToleratesStrayCharactersAroundJSON() throws {
        // A real reply from a small local model: valid array followed by a stray brace.
        let reply = #"[{"candidateID":0,"reason":"'olama' sounds like 'Ollama'.","learningAction":"addReplacementAndVocabulary","incorrectTextToReplace":"olama","correctedVocabularyTerm":"Ollama"}]}"#
        let array = try #require(AutoLearnAIReviewer.firstJSONArray(in: reply))
        #expect(array.hasSuffix("}]"))
        #expect(AutoLearnAIReviewer.firstJSONArray(in: "```json\n[{\"candidateID\":0}]\n```") == #"[{"candidateID":0}]"#)
        #expect(AutoLearnAIReviewer.firstJSONArray(in: "no decisions") == nil)
    }

    @Test func autoLearnSeesSentChatMessageLeaveTheField() {
        // A Chromium composer reads "\n" when empty, as the Claude app's does after Enter sends.
        let pasted = "Add the setup with the Gracki and the Alama model to the README.md."
        func snapshot(final: String) -> AutoLearnFieldSnapshot {
            AutoLearnFieldSnapshot(
                baselineFieldText: pasted + "\n",
                finalFieldText: final,
                pastedRange: NSRange(location: 0, length: pasted.utf16.count),
                originalPastedText: pasted
            )
        }
        #expect(FinalSnapshotDiffEngine.currentPastedText(in: snapshot(final: "\n")) == "")
        #expect(
            FinalSnapshotDiffEngine.currentPastedText(
                in: snapshot(final: "Add the setup with the Groq key and the Ollama model to the README.md.\n")
            ) == "Add the setup with the Groq key and the Ollama model to the README.md."
        )
    }

    @MainActor
    @Test func autoLearnTellsMisheardNamesFromEverydayWords() {
        // Misheard names seen in real runs; automatic language detection accepted them as words.
        for misheard in ["Versal", "Alama", "Gracki", "superbass"] {
            #expect(!AutoLearnEverydayWordGuard.isEverydayWord(misheard), "\(misheard)")
        }
        for everyday in ["print", "grok"] {
            #expect(AutoLearnEverydayWordGuard.isEverydayWord(everyday), "\(everyday)")
        }
        #expect(!AutoLearnEverydayWordGuard.isEverydayWord("super base"))
    }
}
