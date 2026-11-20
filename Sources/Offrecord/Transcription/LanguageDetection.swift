@preconcurrency import AVFoundation
@preconcurrency import Speech

/// Transcribes one live audio source in every candidate language until one of them
/// clearly understands the speech (see `LanguageScore`), then keeps only that one.
/// The winner's results from before the decision are passed on too, so the
/// transcript is in the right language from the first sentence.
final class LanguageDetectingTranscriber: LiveTranscribing, @unchecked Sendable {
    /// Audio after which the best language so far wins if anything was said.
    static let decisionDeadline: TimeInterval = 90
    /// Audio after which the best language wins even without speech, to stop running several models.
    static let giveUpAfter: TimeInterval = 300

    private struct Candidate {
        let transcriber: LiveTranscriber
        var score = LanguageScore()
        var heldResults: [TranscriptionChunk] = []
    }

    private let speaker: Speaker
    private let onChunk: @Sendable (Speaker, TranscriptionChunk) -> Void
    private let lock = NSLock()
    private var candidates: [Candidate] = []
    private var winner: Int?
    /// Best candidate so far; its in-progress text is shown while detecting.
    private var leader = 0
    private var audioSeconds: TimeInterval = 0

    private init(speaker: Speaker, onChunk: @escaping @Sendable (Speaker, TranscriptionChunk) -> Void) {
        self.speaker = speaker
        self.onChunk = onChunk
    }

    /// A plain `LiveTranscriber` for one language, a detecting one for several.
    /// Languages whose model cannot start are skipped.
    static func start(
        speaker: Speaker,
        languages: [Locale],
        farField: Bool,
        onChunk: @escaping @Sendable (Speaker, TranscriptionChunk) -> Void
    ) async throws -> any LiveTranscribing {
        if languages.count == 1 {
            return try await LiveTranscriber.start(speaker: speaker, locale: languages[0], farField: farField, onChunk: onChunk)
        }
        let detector = LanguageDetectingTranscriber(speaker: speaker, onChunk: onChunk)
        var started: [LiveTranscriber] = []
        var lastError: Error?
        for locale in languages {
            let index = started.count
            do {
                started.append(try await LiveTranscriber.start(speaker: speaker, locale: locale, farField: farField) { [weak detector] _, chunk in
                    detector?.receive(chunk, from: index)
                })
            } catch {
                lastError = error
            }
        }
        guard !started.isEmpty else { throw lastError ?? TranscriptionError.unsupportedLocale(languages.map(\.identifier).joined(separator: ", ")) }
        detector.lock.withLock {
            detector.candidates = started.map { Candidate(transcriber: $0) }
            if started.count == 1 { detector.winner = 0 }
        }
        return detector
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        let targets: [LiveTranscriber] = lock.withLock {
            if winner == nil {
                audioSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
                let anySpeech = candidates.contains { $0.score.characters > 0 }
                if audioSeconds >= Self.giveUpAfter || (audioSeconds >= Self.decisionDeadline && anySpeech) {
                    decide(force: true)
                }
            }
            return winner.map { [candidates[$0].transcriber] } ?? candidates.map(\.transcriber)
        }
        targets.forEach { $0.feed(buffer) }
    }

    func finish() async {
        let (decided, all) = lock.withLock { (winner.map { candidates[$0].transcriber }, candidates.map(\.transcriber)) }
        if let decided {
            await decided.finish()
            return
        }
        // Still undecided: let every model deliver its last results, then compare.
        for transcriber in all { await transcriber.finish() }
        lock.withLock { decide(force: true, stopOthers: false) }
    }

    private func receive(_ chunk: TranscriptionChunk, from index: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard candidates.indices.contains(index) else { return }
        if let winner {
            if index == winner { onChunk(speaker, chunk) }
            return
        }
        guard chunk.isFinal else {
            if index == leader { onChunk(speaker, chunk) }
            return
        }
        candidates[index].score.add(chunk)
        candidates[index].heldResults.append(chunk)
        leader = LanguageScore.winner(of: candidates.map(\.score), force: true) ?? leader
        decide(force: false)
    }

    /// Picks the language if it is clear (or `force`d), passes on the winner's held
    /// results and stops the others. Call with `lock` held.
    private func decide(force: Bool, stopOthers: Bool = true) {
        guard winner == nil, let index = LanguageScore.winner(of: candidates.map(\.score), force: force) else { return }
        winner = index
        for chunk in candidates[index].heldResults { onChunk(speaker, chunk) }
        candidates[index].heldResults = []
        if stopOthers {
            let losers = candidates.indices.filter { $0 != index }.map { candidates[$0].transcriber }
            Task { for loser in losers { await loser.cancel() } }
        }
        debugLog("\(speaker) language: \(candidates[index].transcriber.locale.identifier) "
                 + candidates.map { String(format: "%.2f/%d", $0.score.meanConfidence, $0.score.characters) }.joined(separator: " "))
    }
}

/// Detects the language of a recorded file by transcribing up to its first few
/// minutes with every candidate language and comparing their `LanguageScore`.
enum LanguageDetector {
    static let window: TimeInterval = 90
    static let maximumWindows = 4

    static func detect(in url: URL, among candidates: [Locale], farField: Bool) async throws -> Locale {
        guard candidates.count > 1 else { return candidates[0] }
        let file = try AVAudioFile(forReading: url)
        var scores = Array(repeating: LanguageScore(), count: candidates.count)
        for _ in 0..<maximumWindows {
            let excerpt = try readExcerpt(from: file, seconds: window)
            guard !excerpt.isEmpty else { break }
            for (index, locale) in candidates.enumerated() {
                // A language whose model cannot run simply scores nothing.
                if let score = try? await score(excerpt, locale: locale, farField: farField) {
                    scores[index].merge(score)
                }
            }
            if let winner = LanguageScore.winner(of: scores, force: false) {
                return candidates[winner]
            }
        }
        return candidates[LanguageScore.winner(of: scores, force: true) ?? 0]
    }

    private static func readExcerpt(from file: AVAudioFile, seconds: TimeInterval) throws -> [AVAudioPCMBuffer] {
        var buffers: [AVAudioPCMBuffer] = []
        var remaining = AVAudioFramePosition(seconds * file.processingFormat.sampleRate)
        while remaining > 0, file.framePosition < file.length {
            let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(file.processingFormat.sampleRate)))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { break }
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { break }
            buffers.append(buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
        return buffers
    }

    private static func score(_ excerpt: [AVAudioPCMBuffer], locale: Locale, farField: Bool) async throws -> LanguageScore {
        let module = try await TranscriberModule.make(locale: locale, farField: farField)
        try await module.ensureAssets()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module.module], considering: excerpt.first?.format) else {
            throw TranscriptionError.unsupportedLocale(locale.identifier)
        }
        let collector = Task {
            var score = LanguageScore()
            for try await chunk in module.results() { score.add(chunk) }
            return score
        }
        let analyzer = SpeechAnalyzer(modules: [module.module])
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: stream)
        let converter = FormatConverter(outputFormat: format)
        for buffer in excerpt {
            if let converted = converter.convert(buffer) { input.yield(AnalyzerInput(buffer: converted)) }
        }
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }
}
