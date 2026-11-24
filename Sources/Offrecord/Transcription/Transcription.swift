@preconcurrency import AVFoundation
@preconcurrency import Speech

func debugLog(_ message: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["OFFRECORD_DEBUG"] != nil { print("[debug]", message()) }
}

enum TranscriptionError: LocalizedError {
    case unsupportedLocale(String)
    case notAuthorized
    case noAudioTrack

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let id): L("This language isn't supported for on-device transcription: %@", id)
        case .notAuthorized: L("No speech recognition permission. Allow it in System Settings › Privacy & Security › Speech Recognition.")
        case .noAudioTrack: L("No audio found in the file.")
        }
    }
}

struct TranscriptionChunk: Sendable {
    struct Word: Sendable {
        var text: String
        var start: TimeInterval?
        var end: TimeInterval?
    }

    var text: String
    var range: CMTimeRange
    var isFinal: Bool
    var words: [Word] = []
    /// Language of the model that produced the text.
    var locale: Locale?
    /// Model confidence (0...1) averaged over the characters that carry one; final results only.
    var confidence: Double?
    var scoredCharacters = 0

    init(text: AttributedString, range: CMTimeRange, isFinal: Bool, locale: Locale? = nil) {
        self.text = String(text.characters)
        self.range = range
        self.isFinal = isFinal
        self.locale = locale
        guard isFinal else { return }
        var weighted = 0.0
        for (confidence, runRange) in text.runs[\.transcriptionConfidence] {
            guard let confidence else { continue }
            let count = text[runRange].characters.filter { !$0.isWhitespace }.count
            weighted += confidence * Double(count)
            scoredCharacters += count
        }
        if scoredCharacters > 0 { confidence = weighted / Double(scoredCharacters) }
        // Word-level timing from the audioTimeRange attribute runs.
        // Runs are sub-word pieces ("1", "5" or "kararlaştırdı", "k"); a new word
        // starts only after whitespace.
        var pending: Word?
        var atBoundary = true
        for (timeRange, runRange) in text.runs[\.audioTimeRange] {
            let piece = String(text[runRange].characters)
            let start = timeRange.map { $0.start.seconds }
            let end = timeRange.map { $0.end.seconds }
            for character in piece {
                if character.isWhitespace {
                    if let word = pending { words.append(word) }
                    pending = nil
                    atBoundary = true
                    continue
                }
                if atBoundary || pending == nil {
                    pending = Word(text: String(character), start: start, end: end)
                    atBoundary = false
                } else {
                    pending?.text.append(character)
                    if let end { pending?.end = end }
                    if pending?.start == nil { pending?.start = start }
                }
            }
        }
        if let word = pending { words.append(word) }
    }
}

/// Wraps the two on-device transcribers. `SpeechTranscriber` (long-form model) is
/// preferred; `DictationTranscriber` covers languages it lacks, Turkish included.
enum TranscriberModule {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    var module: any SpeechModule {
        switch self {
        case .speech(let t): t
        case .dictation(let t): t
        }
    }

    var locale: Locale? {
        switch self {
        case .speech(let t): t.selectedLocales.first
        case .dictation(let t): t.selectedLocales.first
        }
    }

    static func make(locale: Locale, farField: Bool) async throws -> TranscriberModule {
        // supportedLocale(equivalentTo:) can return a locale that is not actually
        // supported, so always match against the explicit supported list.
        if SpeechTranscriber.isAvailable, let match = bestMatch(for: locale, in: await SpeechTranscriber.supportedLocales) {
            return .speech(SpeechTranscriber(
                locale: match,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence]
            ))
        }
        if let match = bestMatch(for: locale, in: await DictationTranscriber.supportedLocales) {
            return .dictation(DictationTranscriber(
                locale: match,
                contentHints: farField ? [.farField] : [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults, .frequentFinalization],
                attributeOptions: [.audioTimeRange, .transcriptionConfidence]
            ))
        }
        throw TranscriptionError.unsupportedLocale(locale.identifier)
    }

    /// Exact identifier match first, then same language (any region).
    static func bestMatch(for locale: Locale, in supported: [Locale]) -> Locale? {
        let id = locale.identifier(.bcp47)
        if let exact = supported.first(where: { $0.identifier(.bcp47) == id }) { return exact }
        let language = locale.language.languageCode?.identifier
        return supported.first { $0.language.languageCode?.identifier == language }
    }

    /// Languages offered in the UI: union of both transcribers, sorted by display name.
    static func availableLocales() async -> [Locale] {
        var seen = Set<String>()
        let all = await SpeechTranscriber.supportedLocales + DictationTranscriber.supportedLocales
        return all.filter { seen.insert($0.identifier(.bcp47)).inserted }
            .sorted { displayName($0) < displayName($1) }
    }

    static func displayName(_ locale: Locale) -> String {
        AppLanguage.current.locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// Downloads the on-device model for the language the first time it is used.
    func ensureAssets() async throws {
        if let locale {
            let reserved = await AssetInventory.reservedLocales
            if !reserved.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
                do {
                    let ok = try await AssetInventory.reserve(locale: locale)
                    debugLog("reserve \(locale.identifier): \(ok)")
                } catch {
                    debugLog("reserve \(locale.identifier) failed: \(error)")
                }
            }
            let status = await AssetInventory.status(forModules: [module])
            debugLog("asset status before: \(status)")
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    func results() -> AsyncThrowingStream<TranscriptionChunk, Error> {
        let locale = self.locale
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch self {
                    case .speech(let t):
                        for try await r in t.results {
                            continuation.yield(TranscriptionChunk(text: r.text, range: r.range, isFinal: r.isFinal, locale: locale))
                        }
                    case .dictation(let t):
                        for try await r in t.results {
                            continuation.yield(TranscriptionChunk(text: r.text, range: r.range, isFinal: r.isFinal, locale: locale))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func requestAuthorization() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return true }
        if status != .notDetermined { return false }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }
}

/// Something that transcribes one live audio source: a `LiveTranscriber`, or a
/// `LanguageDetectingTranscriber` that picks the language first.
protocol LiveTranscribing: AnyObject, Sendable {
    /// Feeds a 48 kHz mono buffer. Called serially from the audio pipeline.
    func feed(_ buffer: AVAudioPCMBuffer)
    /// Flushes remaining audio and waits for the final results.
    func finish() async
}

/// Live, streaming transcription of one audio source in one language.
final class LiveTranscriber: LiveTranscribing, @unchecked Sendable {
    let speaker: Speaker
    private let module: TranscriberModule
    private let analyzer: SpeechAnalyzer
    private let analyzerFormat: AVAudioFormat
    private let converter: FormatConverter
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let inputStream: AsyncStream<AnalyzerInput>
    private var resultsTask: Task<Void, Never>?
    private let activity = VoiceActivity()

    /// The language the model transcribes.
    let locale: Locale

    private init(speaker: Speaker, module: TranscriberModule, format: AVAudioFormat, locale: Locale) {
        self.locale = locale
        self.speaker = speaker
        self.module = module
        self.analyzerFormat = format
        self.converter = FormatConverter(outputFormat: format)
        self.analyzer = SpeechAnalyzer(modules: [module.module])
        (inputStream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
    }

    /// Prepares the model (downloading it if needed) and starts analysing.
    /// `onChunk` receives volatile and final text on an arbitrary thread.
    static func start(
        speaker: Speaker,
        locale: Locale,
        farField: Bool,
        onChunk: @escaping @Sendable (Speaker, TranscriptionChunk) -> Void
    ) async throws -> LiveTranscriber {
        let module = try await TranscriberModule.make(locale: locale, farField: farField)
        try await module.ensureAssets()
        let natural = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioPipeline.sampleRate, channels: 1, interleaved: false)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module.module], considering: natural) else {
            throw TranscriptionError.unsupportedLocale(locale.identifier)
        }
        let transcriber = LiveTranscriber(speaker: speaker, module: module, format: format, locale: module.locale ?? locale)
        let results = module.results()
        transcriber.resultsTask = Task.detached { [activity = transcriber.activity] in
            do {
                for try await chunk in results {
                    if activity.containsSound(in: chunk.range) {
                        onChunk(speaker, chunk)
                    } else if chunk.isFinal {
                        // Made up from silence: an empty final still clears the live text.
                        onChunk(speaker, TranscriptionChunk(text: "", range: chunk.range, isFinal: true, locale: chunk.locale))
                    }
                }
            } catch {
                // Analyzer was cancelled or failed; recording continues without live text.
            }
        }
        try await transcriber.analyzer.start(inputSequence: transcriber.inputStream)
        return transcriber
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        activity.add(buffer)
        guard let converted = converter.convert(buffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    func finish() async {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
    }

    /// Stops at once, dropping audio not analysed yet and any further results.
    func cancel() async {
        input.finish()
        resultsTask?.cancel()
        await analyzer.cancelAndFinishNow()
    }
}

/// Transcribes a finished audio/video file (re-transcription and file import).
enum FileTranscriber {
    struct Result: Sendable {
        var segments: [TranscriptSegment]
        /// The language used: the fixed one, or the one detected.
        var locale: Locale
    }

    static func transcribe(
        url: URL,
        language: SpeechLanguage,
        speaker: Speaker = .room,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        guard await TranscriberModule.requestAuthorization() else { throw TranscriptionError.notAuthorized }

        var audioURL = url
        var temporary: URL?
        if (try? AVAudioFile(forReading: url)) == nil {
            progress?(L("Extracting audio…"))
            let tmp = FileManager.default.temporaryDirectory.appending(path: "offrecord-\(UUID().uuidString).m4a")
            try await AudioMerger.extractAudio(from: url, to: tmp)
            audioURL = tmp
            temporary = tmp
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }

        progress?(L("Preparing the language model…"))
        let farField = speaker == .room
        let candidates = language.candidates
        var locale = candidates[0]
        if candidates.count > 1 {
            progress?(L("Detecting the language…"))
            locale = try await LanguageDetector.detect(in: audioURL, among: candidates, farField: farField)
        }
        let module = try await TranscriberModule.make(locale: locale, farField: farField)
        try await module.ensureAssets()

        progress?(L("Transcribing…"))
        let activity = try VoiceActivity.scan(audioURL)
        let file = try AVAudioFile(forReading: audioURL)
        let collector = Task {
            var segments: [TranscriptSegment] = []
            for try await chunk in module.results() where chunk.isFinal && activity.containsSound(in: chunk.range) {
                segments += SentenceBuilder.segments(from: chunk, speaker: speaker, locale: locale)
            }
            return segments
        }
        let analyzer = SpeechAnalyzer(modules: [module.module])
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return Result(segments: try await collector.value, locale: locale)
    }
}
