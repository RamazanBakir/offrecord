import Foundation

/// `--transcript-test`: checks echo removal, speaker attribution, the language
/// decision rule and the language setting migration. Prints PASS/FAIL per case.
@MainActor
enum TranscriptCleanupTest {
    static func run() {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print(condition ? "  PASS" : "  FAIL", label)
            if !condition { failures += 1 }
        }
        func line(_ speaker: Speaker, _ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TranscriptSegment {
            TranscriptSegment(speaker: speaker, start: start, end: end, text: text)
        }

        print("== Echo filter")
        let transcript = [
            line(.others, 34.6, 35.4, "Karşıya."),
            line(.me, 34.6, 35.5, "Karşıya."),
            line(.others, 162.5, 164.0, "Coming uçak okay."),
            line(.me, 162.8, 164.1, "Uçak okay."),
            line(.me, 40.0, 42.0, "I will send the deck tomorrow."),
            line(.others, 40.5, 42.5, "Sounds good, thanks."),
            line(.me, 90.0, 91.0, "Karşıya."),
        ]
        let cleaned = EchoFilter.removingEchoes(from: transcript)
        check(!cleaned.contains { $0.speaker == .me && $0.start == 34.6 }, "identical line at the same time removed")
        check(!cleaned.contains { $0.speaker == .me && $0.start == 162.8 }, "partial repeat removed")
        check(cleaned.contains { $0.start == 40.0 }, "my own different words kept")
        check(cleaned.contains { $0.start == 90.0 }, "same words much later kept")
        check(cleaned.filter { $0.speaker == .others }.count == 3, "other side untouched")
        check(EchoFilter.isEcho(line(.me, 1, 2, "ÇOK İYİ!"), of: line(.others, 1.2, 2, "çok iyi")), "case, accents and punctuation ignored")

        print("== Speaker attribution")
        let previous = [
            line(.others, 0, 10, "garbled"), line(.me, 0.2, 10, "garbled echo"),
            line(.me, 12, 15, "garbled"),
            line(.others, 20, 20, "zero length"),
        ]
        let fresh = [
            line(.room, 1, 9, "It's called Bastion."),
            line(.room, 12.5, 14, "Let me check."),
            line(.room, 19.8, 20.3, "Okay."),
            line(.room, 30, 31, "Bye."),
        ]
        let assigned = SpeakerAttribution.assign(fresh, from: previous).map(\.speaker)
        check(assigned == [.others, .me, .others, .others], "speakers from overlap, echo goes to the other side (\(assigned))")
        let inPerson = SpeakerAttribution.assign(fresh, from: [line(.room, 0, 40, "x")]).map(\.speaker)
        check(inPerson.allSatisfy { $0 == .room }, "room recordings keep one speaker")

        print("== Language decision")
        func score(_ confidence: Double, _ characters: Int) -> LanguageScore {
            var score = LanguageScore()
            var chunk = TranscriptionChunk(text: AttributedString(String(repeating: "a", count: characters)), range: .zero, isFinal: true)
            chunk.confidence = confidence
            chunk.scoredCharacters = characters
            score.add(chunk)
            return score
        }
        check(LanguageScore.winner(of: [score(0.12, 80), score(0.9, 60)], force: false) == 1, "clear winner")
        check(LanguageScore.winner(of: [score(0.2, 80), score(0, 0)], force: false) == nil, "waits for every language to produce text")
        check(LanguageScore.winner(of: [score(0.9, 20), score(0.1, 20)], force: false) == nil, "waits for enough text")
        check(LanguageScore.winner(of: [score(0.4, 80), score(0.05, 40)], force: false) == nil, "low confidence never wins early")
        check(LanguageScore.winner(of: [score(0.2, 80), score(0, 0)], force: true) == 0, "forced: best so far")
        check(LanguageScore.winner(of: [LanguageScore(), LanguageScore()], force: true) == 0, "forced without speech: first language")

        print("== Language setting")
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey: SettingsKeys.localeIdentifier), defaults.object(forKey: "speechLanguageMigratedToAutomatic"))
        let system = SettingsKeys.defaultSpeechLocale
        let other = system.hasPrefix("de") ? "fr_FR" : "de_DE"
        for (stored, expected) in [(system, SpeechLanguage.automaticIdentifier), (other, other)] {
            defaults.set(stored, forKey: SettingsKeys.localeIdentifier)
            defaults.removeObject(forKey: "speechLanguageMigratedToAutomatic")
            SpeechLanguage.migrateDefaultChoice()
            check(SpeechLanguage.saved.identifier == expected, "stored \(stored) becomes \(expected)")
        }
        defaults.set(system, forKey: SettingsKeys.localeIdentifier)
        SpeechLanguage.migrateDefaultChoice()
        check(SpeechLanguage.saved.identifier == system, "migration runs only once")
        defaults.set(saved.0, forKey: SettingsKeys.localeIdentifier)
        defaults.set(saved.1, forKey: "speechLanguageMigratedToAutomatic")
        check(SpeechLanguage.automatic.candidates.count <= 2, "automatic tries at most two languages")

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
    }
}
