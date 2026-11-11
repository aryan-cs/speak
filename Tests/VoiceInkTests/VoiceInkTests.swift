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

    @Test func autoLearnMatchesPastesTheEditorReflowed() {
        // A real paste: two paragraphs with smart quotes. The Claude app's box read it back with
        // one newline between paragraphs and Speak could not find its own paste.
        let pasted = "For example, when I say the word “whisper flow,” it is wrong.\n\nBut when I changed it. "
        let field = "For example, when I say the word \"whisper flow,\" it is wrong.\nBut when I changed it.\n"
        #expect(AutoLearnTextNormalizer.accessibilityComparable(pasted) == AutoLearnTextNormalizer.accessibilityComparable(field))
    }

    @Test func autoLearnIgnoresEditsThatReplaceThePasteWholesale() {
        // Queued from a browser address bar, which shows the search URL after Return.
        #expect(!AutoLearnTextSimilarity.isCorrection(of: "Does AirCard work? Are cards still functional", to: "google.com/search"))
        #expect(!AutoLearnTextSimilarity.isCorrection(of: "Help me plan an intern trip to the Catskill Mountains.", to: "Ask Gemini"))
        // Real corrections the user made.
        #expect(AutoLearnTextSimilarity.isCorrection(of: "I'm using Whisperflow and it's just", to: "I'm using WisprFlow and it's just"))
        #expect(AutoLearnTextSimilarity.isCorrection(of: "Walker Tootie and Humanoid look", to: "Walker2d and Humanoid look"))
        #expect(AutoLearnTextSimilarity.isCorrection(of: "we're in a C group", to: "we're in a cgroup"))
    }

    @Test func silenceGuardDropsStockLinesOnlyWhenNoOneSpoke() {
        // Peak speech probabilities measured on real recordings Whisper transcribed.
        #expect(SilenceHallucinationGuard.filter("Thank you.", peakSpeechProbability: 0.596) == "")
        #expect(SilenceHallucinationGuard.filter("you", peakSpeechProbability: 0.653) == "")
        #expect(SilenceHallucinationGuard.filter(".", peakSpeechProbability: 0.616) == "")
        #expect(SilenceHallucinationGuard.filter("Thank you. Thank you.", peakSpeechProbability: 0.5) == "")
        // Real thanks, spoken clearly.
        #expect(SilenceHallucinationGuard.filter("Thank you.", peakSpeechProbability: 1.0) == "Thank you.")
        // Quiet real speech the detector scored low; Parakeet heard the same words.
        #expect(SilenceHallucinationGuard.filter("Try now.", peakSpeechProbability: 0.393) == "Try now.")
        #expect(SilenceHallucinationGuard.filter("Or not?", peakSpeechProbability: 0.795) == "Or not?")
        #expect(SilenceHallucinationGuard.filter("Thank you for the help.", peakSpeechProbability: 0.5) == "Thank you for the help.")
        #expect(SilenceHallucinationGuard.filter("...", peakSpeechProbability: 1.0) == "")
        #expect(SilenceHallucinationGuard.filter("2", peakSpeechProbability: 1.0) == "2")
    }

    @Test func silenceGuardRecognizesStockLinesInOtherLanguages() {
        #expect(SilenceHallucinationGuard.isSilencePhrase("Sous-titres réalisés par la communauté d'Amara.org"))
        #expect(SilenceHallucinationGuard.isSilencePhrase("ご視聴ありがとうございました"))
        #expect(SilenceHallucinationGuard.isSilencePhrase("Thanks for watching! Bye."))
        #expect(!SilenceHallucinationGuard.isSilencePhrase("Thanks for watching the build, then deploy it."))
        #expect(!SilenceHallucinationGuard.isSilencePhrase("Visit amara.org"))
    }

    @Test func silenceGuardDropsOnlyStockLinesSaidOverSilence() {
        // 30.3 s recording, speech until 27.75 s (as in a real one), then room tone.
        let frame = 4096.0 / 16_000
        let probabilities = (0..<119).map { Double($0) * frame < 27.75 ? Float(1.0) : Float(0.3) }
        let transcript = SegmentedTranscript(
            text: " Keep the lighter fill. Thank you. Things aren't aligned. Thank you.",
            segments: [
                .init(start: 0, end: 12.0, text: " Keep the lighter fill."),
                .init(start: 12.0, end: 12.8, text: " Thank you."),
                .init(start: 12.8, end: 27.76, text: " Things aren't aligned."),
                .init(start: 27.76, end: 30.29, text: " Thank you."),
            ])
        let dropped = SilenceHallucinationGuard.droppedSegments(transcript.segments!, frameProbabilities: probabilities)
        #expect(dropped == IndexSet([3]))
        #expect(
            SilenceHallucinationGuard.text(of: transcript, dropping: dropped)
                == "Keep the lighter fill. Thank you. Things aren't aligned.")
    }

    @Test func vocabularyBoostingNeverPadsTheCtcWindowWithSilence() {
        // Silence padding left the CTC model with no output for clips under ~5 s and for the
        // last window of longer audio, so every window must hold real audio.
        let window = ParakeetVocabularyBooster.modelWindowSamples
        let short = (0..<48_000).map { Float($0 % 7) }
        let filled = ParakeetVocabularyBooster.filledForModelWindow(short)
        #expect(filled.count == window)
        #expect(Array(filled.prefix(short.count)) == short)
        #expect(Array(filled[short.count..<(short.count * 2)]) == short)

        let long = [Float](repeating: 0.5, count: window + 16_000)
        let extended = ParakeetVocabularyBooster.filledForModelWindow(long)
        #expect(extended.count == long.count + window)
        #expect(Array(extended.prefix(long.count)) == long)
        #expect(ParakeetVocabularyBooster.filledForModelWindow([]).isEmpty)
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
