import Foundation
import FoundationModels
import NaturalLanguage

/// Produces meeting notes fully on-device. Uses Apple Intelligence when it is
/// enabled and supports the language; otherwise falls back to a rule-based extractor.
enum NoteGenerator {
    static func generate(transcript: [TranscriptSegment], manualNotes: [ManualNote], locale: Locale) async -> GeneratedNotes {
        let text = transcript.map { "\($0.speaker.label): \($0.text)" }.joined(separator: "\n")
        if !text.isEmpty, AppleIntelligenceNotes.isAvailable(for: locale),
           let notes = try? await AppleIntelligenceNotes.generate(transcript: text, manualNotes: manualNotes) {
            return notes
        }
        return HeuristicNotes.generate(transcript: transcript, manualNotes: manualNotes, locale: locale)
    }

    static func engineDescription(for locale: Locale) -> String {
        AppleIntelligenceNotes.isAvailable(for: locale)
            ? L("Apple Intelligence (on-device)")
            : L("On-device rules")
    }

    /// Display name for a stored engine value (older notes stored it in Turkish).
    static func engineLabel(_ stored: String) -> String {
        stored.contains("Apple") ? L("Apple Intelligence (on-device)") : L("On-device rules")
    }
}

// MARK: - Apple Intelligence

@Generable
struct MeetingNotesDraft {
    @Guide(description: "3 to 5 sentences summarising the conversation")
    var summary: [String]
    @Guide(description: "Main topics discussed, short phrases")
    var keyPoints: [String]
    @Guide(description: "Decisions that were agreed on")
    var decisions: [String]
    @Guide(description: "Concrete follow-up tasks, with owner and due date when mentioned")
    var actionItems: [String]
    @Guide(description: "Questions that were left open")
    var openQuestions: [String]
}

enum AppleIntelligenceNotes {
    /// Characters per chunk; keeps each request well inside the model context window.
    private static let chunkSize = 6_000

    static func isAvailable(for locale: Locale) -> Bool {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return false }
        return model.supportsLocale(locale)
    }

    static func generate(transcript: String, manualNotes: [ManualNote]) async throws -> GeneratedNotes {
        let instructions = """
        You write concise, factual meeting notes. Always answer in the same language as the transcript. \
        Never invent facts that are not in the transcript.
        """

        // Long transcripts: condense chunk by chunk first, then write notes from the condensed text.
        var material = transcript
        if transcript.count > chunkSize {
            var condensed: [String] = []
            for chunk in transcript.chunked(into: chunkSize) {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: "Condense this part of a meeting transcript into dense bullet notes, keeping names, numbers, dates, decisions and tasks:\n\n\(chunk)")
                condensed.append(response.content)
            }
            material = condensed.joined(separator: "\n")
            if material.count > chunkSize { material = String(material.prefix(chunkSize)) }
        }

        var prompt = "Write meeting notes for this conversation.\n\n\(material)"
        if !manualNotes.isEmpty {
            prompt += "\n\nNotes the user typed during the meeting (treat as important):\n"
            prompt += manualNotes.map { "- \($0.text)" }.joined(separator: "\n")
        }

        let session = LanguageModelSession(instructions: instructions)
        let draft = try await session.respond(to: prompt, generating: MeetingNotesDraft.self).content
        return GeneratedNotes(
            summary: draft.summary,
            keyPoints: draft.keyPoints,
            decisions: draft.decisions,
            actionItems: draft.actionItems,
            questions: draft.openQuestions,
            engine: L("Apple Intelligence (on-device)"),
            createdAt: .now
        )
    }
}

// MARK: - Rule-based fallback

enum HeuristicNotes {
    static func generate(transcript: [TranscriptSegment], manualNotes: [ManualNote], locale: Locale) -> GeneratedNotes {
        let sentences = transcript.flatMap { segment in
            splitSentences(segment.text).map { (speaker: segment.speaker, text: $0) }
        }
        let texts = sentences.map(\.text)
        let frequencies = wordFrequencies(texts, locale: locale)
        let nouns = nouns(in: texts.joined(separator: " "), locale: locale)

        return GeneratedNotes(
            summary: summary(texts, frequencies: frequencies, locale: locale),
            keyPoints: topTerms(frequencies, nouns: nouns).map { $0.capitalized(with: locale) },
            decisions: unique(texts.filter { matches($0, Patterns.decision, locale: locale) }),
            actionItems: unique(sentences.filter { isTask($0.text, locale: locale) && !$0.text.hasSuffix("?") }.map {
                $0.speaker == .room ? $0.text : "\($0.speaker.label): \($0.text)"
            }),
            questions: unique(texts.filter { $0.hasSuffix("?") && $0.split(separator: " ").count >= 3 }),
            engine: L("On-device rules"),
            createdAt: .now
        )
    }

    private enum Patterns {
        static let action = [
            // Turkish
            "yapacağım", "yapacağız", "yapalım", "yapılacak", "yapılması", "göndereceğim", "gönderirim", "gönderelim",
            "hazırlayacağım", "hazırlarım", "hazırlayalım", "ileteceğim", "iletirim", "bakacağım", "bakarım", "bakalım",
            "halledeceğim", "hallederim", "ayarlayacağım", "ayarlarım", "takip edeceğim", "takip ederim", "kontrol edeceğim",
            "dönüş yapacağım", "dönerim", "paylaşacağım", "paylaşırım", "yazacağım", "yazarım", "arayacağım", "ararım",
            "gerekiyor", "lazım", "yapmamız", "son tarih", "teslim", "yarına kadar", "haftaya", "cumaya kadar",
            "pazartesiye kadar", "ay sonuna", "aksiyon",
            // English
            "i'll", "i will", "we'll", "we will", "will send", "need to", "needs to", "have to", "action item",
            "follow up", "follow-up", "deadline", "due ", "by monday", "by friday", "by tomorrow", "next week", "to do", "todo",
        ]
        static let decision = [
            "karar", "anlaştık", "kesinleşti", "onaylandı", "onayladık", "netleşti", "böyle yapıyoruz", "öyle yapalım",
            "bununla gidelim", "uzlaştık",
            "decided", "decision", "agreed", "we'll go with", "let's go with", "approved", "final answer",
        ]
    }

    /// Turkish future / obligation verb forms ("düzeltecek", "göndereceğim", "yapmalıyız").
    private static let turkishTaskVerb = try! NSRegularExpression(
        pattern: "\\p{L}{2,}(acak|ecek|acağım|eceğim|acağız|eceğiz|acaklar|ecekler|malı|meli|malıyız|meliyiz)\\b",
        options: [.caseInsensitive]
    )
    /// Future forms that describe the meeting itself, not a task.
    private static let meetingVerbs = ["konuşacağız", "bakacağız", "görüşeceğiz", "değineceğiz", "anlatacağım", "bahsedeceğim"]
    /// Future forms that describe events rather than someone's task.
    private static let eventVerbs = [
        "olacak", "artacak", "azalacak", "gelecek", "düşecek", "yükselecek", "değişecek", "sürecek", "bitecek", "çıkacak",
        "geçecek", "kalacak", "olmayacak",
    ]

    /// Lower-cases with the transcript's language rules (Turkish "I" is "ı", English "I" is "i").
    private static func fold(_ text: String, _ locale: Locale) -> String {
        text.lowercased(with: locale)
    }

    private static func matches(_ sentence: String, _ patterns: [String], locale: Locale) -> Bool {
        let lower = fold(sentence, locale)
        return patterns.contains { lower.contains($0) }
    }

    private static func isTask(_ sentence: String, locale: Locale) -> Bool {
        if matches(sentence, Patterns.action, locale: locale) { return true }
        let lower = fold(sentence, locale)
        if meetingVerbs.contains(where: { lower.contains($0) }) { return false }
        let range = NSRange(lower.startIndex..., in: lower)
        let matches = turkishTaskVerb.matches(in: lower, range: range).compactMap { Range($0.range, in: lower).map { String(lower[$0]) } }
        return matches.contains { !eventVerbs.contains($0) }
    }

    private static func splitSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            return true
        }
        return out
    }

    private static func words(_ text: String, locale: Locale) -> [String] {
        fold(text, locale)
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    private static func wordFrequencies(_ sentences: [String], locale: Locale) -> [String: Int] {
        var counts: [String: Int] = [:]
        for s in sentences { for w in words(s, locale: locale) { counts[w, default: 0] += 1 } }
        return counts
    }

    /// Extractive summary: highest-scoring sentences, kept in original order.
    private static func summary(_ sentences: [String], frequencies: [String: Int], locale: Locale) -> [String] {
        let candidates = sentences.enumerated().filter { $0.element.split(separator: " ").count >= 6 && !$0.element.hasSuffix("?") }
        guard !candidates.isEmpty else { return Array(sentences.prefix(3)) }
        let scored = candidates.map { item -> (Int, String, Double) in
            let ws = words(item.element, locale: locale)
            let score = ws.isEmpty ? 0 : Double(ws.reduce(0) { $0 + (frequencies[$1] ?? 0) }) / sqrt(Double(ws.count))
            return (item.offset, item.element, score)
        }
        let count = min(5, max(3, scored.count / 10 + 2))
        return scored.sorted { $0.2 > $1.2 }.prefix(count).sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Lower-cased nouns in `text` (topics are things, not verbs like "need" or "check").
    private static func nouns(in text: String, locale: Locale) -> Set<String> {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        if let code = locale.language.languageCode?.identifier { tagger.setLanguage(NLLanguage(code), range: text.startIndex..<text.endIndex) }
        var result = Set<String>()
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            if tag == .noun { result.insert(fold(String(text[range]), locale)) }
            return true
        }
        return result
    }

    /// Groups inflected forms by their first five letters (a simple, well-known
    /// stemmer for Turkish: "tarih", "tarihini", "tarihte" -> "tarih"), shows the
    /// shortest form of each group and prefers groups that contain a noun.
    private static func topTerms(_ frequencies: [String: Int], nouns: Set<String>) -> [String] {
        var groups: [String: (count: Int, display: String, hasNoun: Bool)] = [:]
        for (word, count) in frequencies where word.count >= 4 {
            let key = String(word.prefix(5))
            let existing = groups[key]
            let display = existing.map { $0.display.count <= word.count ? $0.display : word } ?? word
            groups[key] = ((existing?.count ?? 0) + count, display, (existing?.hasNoun ?? false) || nouns.contains(word))
        }
        let ranked = groups.values
            .filter { $0.count >= 2 }
            .sorted { $0.count == $1.count ? $0.display < $1.display : $0.count > $1.count }
        let withNouns = ranked.filter(\.hasNoun)
        return (withNouns.count >= 3 ? withNouns : ranked).prefix(8).map(\.display)
    }

    private static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.lowercased()).inserted }.prefix(25).map { $0 }
    }

    private static let stopWords: Set<String> = [
        // Turkish
        "acaba", "ama", "ancak", "artık", "aslında", "bana", "bazı", "belki", "ben", "beni", "benim", "bile", "bir",
        "biraz", "birçok", "biri", "birkaç", "birşey", "biz", "bize", "bizi", "bizim", "böyle", "bu", "buna", "bunu",
        "bunun", "burada", "çok", "çünkü", "da", "daha", "de", "değil", "diye", "dolayı", "en", "evet", "falan", "filan",
        "gibi", "göre", "hani", "hayır", "hem", "hep", "hepsi", "her", "hiç", "için", "ile", "ise", "işte", "kadar",
        "ki", "kim", "mesela", "mi", "mı", "mu", "mü", "nasıl", "ne", "neden", "nerede", "niye", "o", "olan", "olarak",
        "oldu", "olduğu", "olsun", "on", "ona", "onu", "onun", "orada", "öyle", "sadece", "sen", "sana", "seni", "şey",
        "şeyi", "şimdi", "şöyle", "şu", "şuna", "şunu", "tabi", "tabii", "tamam", "tüm", "var", "vardı", "ve", "veya",
        "ya", "yani", "yok", "zaten", "olur", "oluyor", "yapıyoruz", "diyorum", "diyor", "bence", "sonra", "önce",
        "aynı", "bunlar", "onlar", "şeyler", "galiba", "herhalde", "hadi", "peki", "tam", "iyi", "güzel",
        // English
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our", "out",
        "has", "have", "his", "how", "its", "may", "new", "now", "see", "two", "who", "did", "get", "let", "say", "she",
        "too", "use", "that", "this", "with", "they", "from", "what", "just", "like", "know", "yeah", "okay", "think",
        "there", "about", "would", "could", "should", "really", "going", "right", "well", "also", "then", "them",
        "were", "been", "will", "your", "into", "some", "than", "very", "when", "which", "their", "because",
    ]
}

extension String {
    func chunked(into size: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in split(separator: "\n", omittingEmptySubsequences: true) {
            if current.count + line.count > size, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
