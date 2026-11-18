import Foundation

/// Turns one final transcription result into readable, punctuated sentences.
///
/// Some on-device models (Turkish dictation among them) return long runs of
/// text without punctuation. Sentences are cut at speech pauses (from word
/// timings) and, for Turkish, after finite verb endings, since Turkish
/// sentences are verb-final.
enum SentenceBuilder {
    /// Pause between words that ends a sentence.
    static let pauseThreshold: TimeInterval = 0.7
    /// Do not cut sentences shorter than this many words on grammar alone.
    static let minimumWords = 3

    static func segments(from chunk: TranscriptionChunk, speaker: Speaker, locale: Locale) -> [TranscriptSegment] {
        let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let words = chunk.words.isEmpty
            ? text.split(whereSeparator: \.isWhitespace).map { TranscriptionChunk.Word(text: String($0)) }
            : chunk.words
        let alreadyPunctuated = words.filter { $0.text.last.map { ".?!".contains($0) } ?? false }.count
        let needsSplitting = alreadyPunctuated * 20 < words.count
        let isTurkish = locale.language.languageCode?.identifier == "tr"

        guard needsSplitting else {
            return [TranscriptSegment(speaker: speaker, start: chunk.range.start.seconds, end: chunk.range.end.seconds, text: text)]
        }

        var sentences: [[TranscriptionChunk.Word]] = []
        var current: [TranscriptionChunk.Word] = []
        for (index, word) in words.enumerated() {
            if !current.isEmpty {
                let previous = current[current.count - 1]
                let pause = (word.start ?? 0) - (previous.end ?? 0)
                let pauseBreak = word.start != nil && previous.end != nil && pause >= pauseThreshold
                let grammarBreak = isTurkish && current.count >= minimumWords
                    && (TurkishRules.endsSentence(previous.text) || TurkishRules.startsSentence(word.text))
                    && !TurkishRules.continues(word.text)
                if pauseBreak || grammarBreak || previous.text.last.map({ ".?!".contains($0) }) == true {
                    sentences.append(current)
                    current = []
                }
            }
            current.append(word)
            if index == words.count - 1 { sentences.append(current) }
        }

        let chunkStart = chunk.range.start.seconds
        let chunkEnd = chunk.range.end.seconds
        return sentences.map { group in
            let raw = group.map(\.text).joined(separator: " ")
            return TranscriptSegment(
                speaker: speaker,
                start: group.first?.start ?? chunkStart,
                end: group.last?.end ?? chunkEnd,
                text: punctuate(raw, turkish: isTurkish, locale: locale)
            )
        }
    }

    private static func punctuate(_ sentence: String, turkish: Bool, locale: Locale) -> String {
        var s = sentence.trimmingCharacters(in: .whitespaces)
        guard let first = s.first else { return s }
        s = String(first).uppercased(with: locale) + s.dropFirst()
        if let last = s.last, ".?!,…".contains(last) { return s }
        let isQuestion = turkish ? TurkishRules.isQuestion(s) : false
        return s + (isQuestion ? "?" : ".")
    }
}

enum TurkishRules {
    private static let locale = Locale(identifier: "tr_TR")

    /// Finite verb / predicate endings that typically close a Turkish sentence.
    private static let finalSuffixes = [
        "acağım", "eceğim", "acağız", "eceğiz", "acaksın", "eceksin", "acaklar", "ecekler", "acak", "ecek",
        "yorum", "yoruz", "yorsun", "yorlar", "yor",
        "dım", "dim", "dum", "düm", "tım", "tim", "tum", "tüm",
        "dık", "dik", "duk", "dük", "tık", "tik", "tuk", "tük",
        "dılar", "diler", "dular", "düler", "tılar", "tiler",
        "dı", "di", "du", "dü",
        // Past tense after a voiceless consonant (bitti, yaptı, baktı, geçti, konuştu); a bare
        // "tı/ti" would also match nouns such as "toplantı" or "şirketi".
        "ttı", "tti", "ttu", "ttü", "ptı", "pti", "ptu", "ptü", "ktı", "kti", "ktu", "ktü",
        "stı", "sti", "stu", "stü", "çtı", "çti", "çtu", "çtü", "ştı", "şti", "ştu", "ştü", "ftı", "fti", "htı", "hti",
        "mış", "miş", "muş", "müş",
        "malıyız", "meliyiz", "malı", "meli",
        "alım", "elim", "ayım", "eyim", "lım", "lim",
        "abilir", "ebilir", "abiliriz", "ebiliriz",
        "dır", "dir", "dur", "dür", "tır", "tir", "tur", "tür",
        "sınız", "siniz", "sunuz", "sünüz", "yız", "yiz", "yuz", "yüz",
    ]
    private static let finalWords: Set<String> = [
        "var", "yok", "lazım", "gerek", "gerekiyor", "değil", "tamam", "olur", "olmaz", "evet", "hayır", "teşekkürler",
    ]
    /// Words ending like verbs that are not sentence-final.
    private static let falseFinals: Set<String> = [
        "şimdi", "hadi", "gibi", "iyi", "belki", "biz", "siz", "deniz", "ikimiz", "hepimiz", "hepiniz", "kendimiz",
        "kendiniz", "neyimiz", "bizim", "sizin", "dedi", "yani", "keşke", "artık", "sonradan", "dün", "bütün", "tüm",
        "türlü", "sürü", "ödemeyi", "kadı", "kedi", "adı", "kendi", "ilgili", "hiçbir", "her",
    ]
    private static let sentenceStarters: Set<String> = [
        "peki", "tamam", "evet", "hayır", "ama", "fakat", "ancak", "ayrıca", "sonuç", "yani", "bence", "şimdi", "hadi", "bu arada",
    ]
    /// Words that continue the previous clause.
    private static let continuations: Set<String> = [
        "ve", "ile", "de", "da", "ki", "mi", "mı", "mu", "mü", "diye", "için", "gibi", "kadar", "ya", "veya", "ama",
        "misin", "mısın", "musun", "müsün", "miyiz", "mıyız", "muyuz", "müyüz", "mısınız", "misiniz",
    ]
    private static let questionWords: Set<String> = [
        "kim", "kimi", "kime", "kimin", "ne", "neyi", "neden", "niye", "niçin", "nasıl", "nerede", "nereye", "nereden",
        "hangi", "hangisi", "kaç", "kaçta", "ne zaman", "mi", "mı", "mu", "mü", "misin", "mısın", "musun", "müsün",
        "miyiz", "mıyız", "muyuz", "müyüz", "misiniz", "mısınız", "midir", "mıdır",
    ]

    private static func normalize(_ word: String) -> String {
        word.lowercased(with: locale).trimmingCharacters(in: .punctuationCharacters)
    }

    static func endsSentence(_ word: String) -> Bool {
        let w = normalize(word)
        if finalWords.contains(w) { return true }
        if falseFinals.contains(w) || w.count < 4 { return false }
        return finalSuffixes.contains { w.hasSuffix($0) && w.count > $0.count + 1 }
    }

    static func startsSentence(_ word: String) -> Bool {
        sentenceStarters.contains(normalize(word))
    }

    static func continues(_ word: String) -> Bool {
        continuations.contains(normalize(word))
    }

    static func isQuestion(_ sentence: String) -> Bool {
        let words = sentence.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }
        return words.contains { questionWords.contains($0) }
    }
}
