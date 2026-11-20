import AVFoundation
import Foundation
import Observation
@preconcurrency import ScreenCaptureKit

/// Orchestrates one live session: capture -> files + live transcript -> notes.
@MainActor
@Observable
final class RecordingController {
    enum Phase: Equatable {
        case idle
        case preparing(String)
        case recording
        case finishing(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var meta: SessionMeta?
    private(set) var segments: [TranscriptSegment] = []
    private(set) var volatileText: [Speaker: String] = [:]
    private(set) var manualNotes: [ManualNote] = []
    private(set) var levels: [Speaker: Float] = [:]
    private(set) var startedAt: Date?
    private(set) var liveTranscriptionWarning: String?
    private(set) var isPaused = false
    /// Loudest level seen per source since the start (detects a silent remote side).
    private(set) var peakLevels: [Speaker: Float] = [:]
    private var lastSoundAt = Date()
    /// Last time the remote side was audible (call-end detection).
    private(set) var lastRemoteSoundAt = Date()
    private var silencePrompted = false
    private var housekeeping: Task<Void, Never>?

    /// True when system audio is recorded but nothing has come through for a while.
    var remoteSideSilent: Bool {
        guard isRecording, meta?.options.systemAudio == true, elapsed > 40 else { return false }
        return (peakLevels[.others] ?? 0) < 0.15
    }
    var errorMessage: String?

    /// Id of the last session that finished, so the UI can jump to it.
    private(set) var lastFinishedID: UUID?

    var isActive: Bool { phase != .idle }
    var isRecording: Bool { phase == .recording }

    private let store: SessionStore
    private var record: SessionRecord?
    private var pipelines: [AudioPipeline] = []
    private var transcribers: [any LiveTranscribing] = []
    /// Transcribed characters per language, to tell which language the session is in.
    private var languageCharacters: [String: Int] = [:]
    private var microphone: MicrophoneCapture?
    private var systemAudio: SystemAudioCapture?
    private var screen: ScreenCapture?
    /// Pending screen pause/resume steps, run one after another.
    private var screenWork: Task<Void, Never>?

    init(store: SessionStore) {
        self.store = store
    }

    var elapsed: TimeInterval {
        startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    // MARK: Start

    /// `screenFilter`: what to record when `options.screen` is on (see `ScreenPicker`).
    func start(
        title: String?, kind: SessionKind, options: CaptureOptions, language: SpeechLanguage,
        screenFilter: SCContentFilter? = nil, attendees: [String]? = nil, othersName: String? = nil
    ) async {
        guard phase == .idle else { return }
        errorMessage = nil
        liveTranscriptionWarning = nil
        segments = []
        volatileText = [:]
        manualNotes = []
        levels = [:]
        peakLevels = [:]
        isPaused = false
        silencePrompted = false
        lastSoundAt = Date()
        lastRemoteSoundAt = Date()
        languageCharacters = [:]
        phase = .preparing(L("Checking permissions…"))

        do {
            guard options.microphone || options.systemAudio || options.screen else {
                throw NSError(domain: "Offrecord", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Pick at least one source (microphone, system audio or screen).")])
            }
            if options.screen, screenFilter == nil {
                throw CaptureError.screenTargetGone
            }
            if options.microphone, !(await MicrophoneCapture.requestAccess()) {
                throw CaptureError.microphoneDenied
            }

            let now = Date()
            let resolvedTitle = (title?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "\(kind.title) – \(now.formatted(.dateTime.locale(AppLanguage.current.locale).day().month(.abbreviated).hour().minute()))"
            let meta = SessionMeta(
                id: UUID(), title: resolvedTitle, kind: kind, startedAt: now, duration: 0,
                // Refined to the detected language while recording (see `updateSessionLanguage`).
                options: options, localeIdentifier: language.candidates[0].identifier,
                isComplete: false, attendees: attendees, othersName: othersName
            )
            let record = try store.createFolder(for: meta)
            self.meta = meta
            self.record = record

            // Pipelines (one per audio source).
            let micPipeline = options.microphone
                ? AudioPipeline(speaker: kind.micIsWholeRoom ? .room : .me, fileURL: record.folder.appending(path: SessionFiles.micAudio))
                : nil
            let systemPipeline = options.systemAudio
                ? AudioPipeline(speaker: .others, fileURL: record.folder.appending(path: SessionFiles.systemAudio))
                : nil
            pipelines = [micPipeline, systemPipeline].compactMap { $0 }
            for pipeline in pipelines {
                let speaker = pipeline.speaker
                pipeline.onLevel = { [weak self] level in
                    Task { @MainActor in self?.updateLevel(level, for: speaker) }
                }
            }

            // Live transcription (best effort: recording still works if it fails).
            if options.transcribe, !pipelines.isEmpty {
                await startTranscribers(language: language, farField: kind == .inPerson)
            }

            phase = .preparing(L("Starting recording…"))
            let sessionStart = Date()
            pipelines.forEach { $0.begin(at: sessionStart) }

            if let micPipeline {
                // Voice processing for calls (echo + gain); raw mic for in-person rooms.
                let enhance = UserDefaults.standard.bool(forKey: SettingsKeys.voiceProcessing) && options.systemAudio
                let mic = MicrophoneCapture(voiceProcessing: enhance) { micPipeline.consume($0) }
                try mic.start()
                microphone = mic
            }
            if let systemPipeline {
                let capture = SystemAudioCapture { systemPipeline.consume($0) }
                capture.onError = { [weak self] error in
                    Task { @MainActor in self?.errorMessage = L("System capture stopped: %@", error.localizedDescription) }
                }
                try await capture.start()
                systemAudio = capture
            }
            if options.screen, let screenFilter {
                // Video only: the cleaned-up session audio is added when the parts are assembled.
                let capture = ScreenCapture(filter: screenFilter, folder: record.folder, sessionStart: sessionStart)
                capture.onError = { [weak self] error in
                    Task { @MainActor in
                        self?.errorMessage = L("Screen recording stopped (%@). The audio keeps recording.", error.localizedDescription)
                    }
                }
                screen = capture
                try await capture.start()
            }

            startedAt = sessionStart
            phase = .recording
            startHousekeeping()
        } catch {
            errorMessage = error.localizedDescription
            await teardown(discard: true)
        }
    }

    private func startTranscribers(language: SpeechLanguage, farField: Bool) async {
        guard await TranscriberModule.requestAuthorization() else {
            liveTranscriptionWarning = TranscriptionError.notAuthorized.localizedDescription
            return
        }
        phase = .preparing(L("Preparing the language model (may download the first time)…"))
        for pipeline in pipelines {
            do {
                // Each side detects its own language: the two people may speak different ones.
                let transcriber = try await LanguageDetectingTranscriber.start(
                    speaker: pipeline.speaker,
                    languages: language.candidates,
                    farField: farField || pipeline.speaker == .room
                ) { [weak self] speaker, chunk in
                    Task { @MainActor in self?.handle(chunk, from: speaker) }
                }
                pipeline.attach(transcriber: transcriber)
                transcribers.append(transcriber)
            } catch {
                liveTranscriptionWarning = L("Couldn't start live transcription: %@. Recording continues; you can transcribe from the file afterwards.", error.localizedDescription)
            }
        }
    }

    private func handle(_ chunk: TranscriptionChunk, from speaker: Speaker) {
        let text = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if chunk.isFinal {
            volatileText[speaker] = nil
            let locale = chunk.locale ?? Locale(identifier: meta?.localeIdentifier ?? SettingsKeys.defaultSpeechLocale)
            languageCharacters[locale.identifier, default: 0] += text.count
            for segment in SentenceBuilder.segments(from: chunk, speaker: speaker, locale: locale) {
                insert(segment)
            }
        } else {
            volatileText[speaker] = text.isEmpty ? nil : text
        }
    }

    /// Adds a final line in time order, skipping microphone lines that echo the other side.
    private func insert(_ segment: TranscriptSegment) {
        if segment.speaker == .me, segments.contains(where: { EchoFilter.isEcho(segment, of: $0) }) { return }
        if segment.speaker == .others { segments.removeAll { EchoFilter.isEcho($0, of: segment) } }
        let index = segments.firstIndex { $0.start > segment.start } ?? segments.endIndex
        segments.insert(segment, at: index)
    }

    /// Stores the language most of the transcript is in, so notes (and crash
    /// recovery) use the detected language. Returns the updated metadata.
    @discardableResult
    private func updateSessionLanguage() -> SessionMeta? {
        guard var meta, let dominant = languageCharacters.max(by: { $0.value < $1.value })?.key,
              dominant != meta.localeIdentifier else { return self.meta }
        meta.localeIdentifier = dominant
        self.meta = meta
        if let record { try? store.save(meta: meta, in: record) }
        return meta
    }

    // MARK: During recording

    private func updateLevel(_ level: Float, for speaker: Speaker) {
        levels[speaker] = level
        if level > (peakLevels[speaker] ?? 0) { peakLevels[speaker] = level }
        if speaker == .others, level > 0.2 { lastRemoteSoundAt = Date() }
        if level > 0.3 {
            lastSoundAt = Date()
            silencePrompted = false
        }
    }

    /// Every 15 s: autosave transcript + notes (crash safety) and watch for long silence.
    private func startHousekeeping() {
        housekeeping?.cancel()
        housekeeping = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, self.isRecording, let record = self.record else { continue }
                try? self.store.save(transcript: self.segments, in: record)
                try? self.store.save(manualNotes: self.manualNotes, in: record)
                self.updateSessionLanguage()
                if !self.isPaused, !self.silencePrompted, Date().timeIntervalSince(self.lastSoundAt) > 300 {
                    self.silencePrompted = true
                    Notifications.postSilence()
                }
            }
        }
    }

    func togglePause() {
        guard isRecording else { return }
        isPaused.toggle()
        pipelines.forEach { $0.setPaused(isPaused) }
        let paused = isPaused
        enqueueScreenStep { [weak self] screen in
            if paused {
                await screen.pause()
            } else {
                do {
                    try await screen.resume()
                } catch {
                    self?.errorMessage = L("Couldn't continue the screen recording: %@", error.localizedDescription)
                }
            }
        }
        lastSoundAt = Date()
        manualNotes.append(ManualNote(at: elapsed, text: isPaused ? L("Recording paused") : L("Recording resumed")))
    }

    /// Screen pause/resume are async; chaining them keeps quick toggles in order.
    private func enqueueScreenStep(_ step: @escaping @MainActor (ScreenCapture) async -> Void) {
        guard let screen else { return }
        let previous = screenWork
        screenWork = Task {
            await previous?.value
            await step(screen)
        }
    }

    /// Stops screen capture after any pending pause/resume step.
    private func stopScreen() async {
        await screenWork?.value
        screenWork = nil
        await screen?.stop()
    }

    func addNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRecording, !trimmed.isEmpty else { return }
        manualNotes.append(ManualNote(at: elapsed, text: trimmed))
    }

    func addBookmark() {
        guard isRecording else { return }
        let context = segments.last?.text ?? volatileText.values.first ?? L("Important moment")
        manualNotes.append(ManualNote(at: elapsed, text: context, isBookmark: true))
    }

    // MARK: Stop

    func stop() async {
        guard phase == .recording, let record, var meta else { return }
        housekeeping?.cancel()
        meta.duration = elapsed
        meta.isComplete = true
        phase = .finishing(L("Closing the recording…"))

        microphone?.stop()
        await systemAudio?.stop()
        await stopScreen()

        phase = .finishing(L("Transcribing the last sentences…"))
        for transcriber in transcribers { await transcriber.finish() }
        // Final results hop to the main actor asynchronously; give them time to land.
        try? await Task.sleep(for: .milliseconds(400))
        for (speaker, text) in volatileText where !text.isEmpty {
            segments.append(TranscriptSegment(speaker: speaker, start: meta.duration, end: meta.duration, text: text))
        }
        volatileText = [:]
        segments = EchoFilter.removingEchoes(from: segments)
        if let detected = updateSessionLanguage()?.localeIdentifier { meta.localeIdentifier = detected }
        pipelines.forEach { $0.finish() }

        phase = .finishing(L("Balancing audio levels…"))
        do {
            meta.audioEnhanced = try await AudioMerger.finalize(folder: record.folder, into: record.audioURL)
        } catch {
            errorMessage = L("Couldn't merge audio; the separate files are kept in the folder: %@", error.localizedDescription)
        }
        if meta.options.screen {
            phase = .finishing(L("Preparing the screen recording…"))
            do {
                try await ScreenRecordingAssembler.finalize(folder: record.folder, audio: record.audioURL, into: record.screenURL)
            } catch {
                errorMessage = L("Couldn't finish the screen recording: %@. Whatever was recorded is kept in the session folder.", error.localizedDescription)
            }
        }

        phase = .finishing(L("Writing notes…"))
        try? store.save(meta: meta, in: record)
        try? store.save(transcript: segments, in: record)
        try? store.save(manualNotes: manualNotes, in: record)
        let notes = await NoteGenerator.generate(
            transcript: segments, manualNotes: manualNotes, locale: Locale(identifier: meta.localeIdentifier)
        )
        try? store.save(notes: notes, in: record)
        store.writeMarkdown(for: record)

        lastFinishedID = meta.id
        await teardown(discard: false)
        store.reload()
    }

    private func teardown(discard: Bool) async {
        housekeeping?.cancel()
        housekeeping = nil
        isPaused = false
        microphone?.stop()
        await systemAudio?.stop()
        await stopScreen()
        if discard {
            for transcriber in transcribers { await transcriber.finish() }
            pipelines.forEach { $0.finish() }
            if let record { try? FileManager.default.removeItem(at: record.folder) }
        }
        microphone = nil
        systemAudio = nil
        screen = nil
        transcribers = []
        pipelines = []
        record = nil
        meta = nil
        startedAt = nil
        levels = [:]
        phase = .idle
    }

    /// Fake live state for off-screen UI snapshots.
    func loadPreviewState() {
        meta = SessionMeta(id: UUID(), title: "Weekly team sync", kind: .onlineMeeting, startedAt: .now, duration: 0,
                           options: SessionKind.onlineMeeting.defaultOptions, localeIdentifier: "en_US")
        startedAt = Date().addingTimeInterval(-754)
        phase = .recording
        segments = [
            TranscriptSegment(speaker: .others, start: 12, end: 15, text: "Hi everyone, today we need to agree on the release date."),
            TranscriptSegment(speaker: .me, start: 16, end: 19, text: "The design team finished the landing page."),
            TranscriptSegment(speaker: .others, start: 21, end: 25, text: "Alex will fix the remaining bugs by Friday."),
        ]
        volatileText = [.me: "I will send the deck by tomorrow"]
        manualNotes = [ManualNote(at: 22, text: "Ask Alex about the budget")]
        levels = [.me: 0.6, .others: 0.3]
        peakLevels = levels
    }
}
