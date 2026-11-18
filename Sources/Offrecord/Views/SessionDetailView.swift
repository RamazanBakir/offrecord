import AVFoundation
import SwiftUI

/// A finished session on one scrolling page.
struct SessionDetailView: View {
    @Environment(AppModel.self) private var model
    let record: SessionRecord

    @State private var title = ""
    @State private var othersName = ""
    @State private var transcript: [TranscriptSegment] = []
    @State private var manualNotes: [ManualNote] = []
    @State private var notes: GeneratedNotes?
    @State private var player = AudioPlayer()
    @State private var busy: String?
    @State private var showTranscript = false
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if record.hasAudio {
                    AudioPlayerBar(player: player)
                    if currentMeta.audioEnhanced != true {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform.badge.plus").foregroundStyle(.tint)
                            Text(L("This recording was made without level balancing; quiet voices may be hard to hear."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button(L("Enhance audio"), action: enhanceAudio)
                                .disabled(busy != nil)
                        }
                    }
                }
                if let busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(busy).foregroundStyle(.secondary)
                    }
                }
                content
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItemGroup {
                ShareLink(item: markdown, subject: Text(currentMeta.title)) {
                    Label(L("Share"), systemImage: "square.and.arrow.up")
                }
                .help(L("Share notes via Mail, Notes, Messages…"))
                if record.hasScreen {
                    Button {
                        NSWorkspace.shared.open(record.screenURL)
                    } label: {
                        Label(L("Open screen recording"), systemImage: "play.rectangle")
                    }
                    .help(L("Open screen recording"))
                }
                Button {
                    copyNotes()
                } label: {
                    Label(copied ? L("Copied") : L("Copy notes"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help(L("Copy notes as Markdown"))
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([record.folder])
                } label: {
                    Label(L("Show in Finder"), systemImage: "folder")
                }
                .help(L("Show in Finder"))
                Button {
                    player.stop()
                    model.pendingDelete = record
                } label: {
                    Label(L("Delete"), systemImage: "trash")
                }
                .help(L("Move to Trash (⌘⌫)"))
            }
        }
        .task { load() }
        .onDisappear { player.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(L("Title"), text: $title)
                .textFieldStyle(.plain)
                .font(.title.weight(.semibold))
                .onSubmit(rename)
            Text("\(record.meta.startedAt.formatted(.dateTime.locale(AppLanguage.current.locale).day().month(.wide).hour().minute())) · \(record.meta.duration.clockString)")
                .foregroundStyle(.secondary)
            if let attendees = record.meta.attendees, !attendees.isEmpty {
                Label(attendees.joined(separator: ", "), systemImage: "person.2")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if record.meta.options.systemAudio, transcript.contains(where: { $0.speaker == .others }) {
                HStack(spacing: 6) {
                    Text(L("Them:"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField(L("add a name"), text: $othersName)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.purple)
                        .frame(maxWidth: 220)
                        .onSubmit(saveOthersName)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if transcript.isEmpty, manualNotes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("No transcribed speech in this recording."))
                    .foregroundStyle(.secondary)
                if record.hasAudio || record.hasScreen {
                    Button(L("Transcribe from audio"), action: retranscribe)
                        .disabled(busy != nil)
                }
            }
        } else {
            if let notes {
                if !notes.summary.isEmpty {
                    Block(title: L("Summary")) {
                        Text(notes.summary.joined(separator: " "))
                            .textSelection(.enabled)
                            .lineSpacing(3)
                    }
                }
                if !notes.actionItems.isEmpty {
                    Block(title: L("To-dos")) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(notes.actionItems, id: \.self) { item in
                                TaskRow(text: item, done: notes.isDone(item)) {
                                    model.store.toggleAction(item, in: record)
                                    self.notes = model.store.notes(for: record)
                                }
                            }
                        }
                    }
                }
                Bullets(title: L("Decisions"), items: notes.decisions)
                Bullets(title: L("Open questions"), items: notes.questions)
                if !notes.keyPoints.isEmpty {
                    Block(title: L("Topics")) {
                        Text(notes.keyPoints.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !manualNotes.isEmpty {
                Block(title: L("My notes")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(manualNotes) { note in
                            NoteRow(note: note) { player.seek(to: note.at) }
                        }
                    }
                }
            }

            if !transcript.isEmpty {
                DisclosureGroup(isExpanded: $showTranscript) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(transcript) { segment in
                            SegmentRow(segment: segment, label: currentMeta.label(for: segment.speaker)) { player.seek(to: segment.start) }
                        }
                    }
                    .padding(.top, 12)
                } label: {
                    Text(L("Transcript"))
                        .font(.headline)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation { showTranscript.toggle() } }
                }
            }
        }
    }

    // MARK: Actions

    /// Latest metadata from the store (rename / speaker name edits).
    private var currentMeta: SessionMeta { model.store.record(id: record.id)?.meta ?? record.meta }

    private func saveOthersName() {
        var meta = currentMeta
        let trimmed = othersName.trimmingCharacters(in: .whitespaces)
        meta.othersName = trimmed.isEmpty ? nil : trimmed
        try? model.store.save(meta: meta, in: record)
        model.store.writeMarkdown(for: record)
    }

    private var markdown: String {
        MarkdownRenderer.render(meta: currentMeta, notes: notes, manualNotes: manualNotes, transcript: transcript)
    }

    private func load() {
        othersName = record.meta.othersName ?? ""
        title = record.meta.title
        transcript = model.store.transcript(for: record)
        manualNotes = model.store.manualNotes(for: record)
        notes = model.store.notes(for: record)
        if record.hasAudio { player.load(record.audioURL) }
    }

    private func rename() {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != record.meta.title else { return }
        var meta = currentMeta
        meta.title = trimmed
        try? model.store.save(meta: meta, in: record)
        if let updated = model.store.record(id: record.id) { model.store.writeMarkdown(for: updated) }
    }

    private func copyNotes() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private func enhanceAudio() {
        busy = L("Balancing audio levels…")
        player.stop()
        Task {
            do {
                try await SpeechEnhancer.enhanceInPlace(record.audioURL)
                var meta = currentMeta
                meta.audioEnhanced = true
                try? model.store.save(meta: meta, in: record)
                player.load(record.audioURL)
            } catch {
                model.recorder.errorMessage = L("Couldn't enhance audio: %@", error.localizedDescription)
            }
            busy = nil
        }
    }

    private func retranscribe() {
        let source = record.hasAudio ? record.audioURL : record.screenURL
        let locale = Locale(identifier: record.meta.localeIdentifier)
        busy = L("Preparing…")
        Task {
            do {
                let segments = try await FileTranscriber.transcribe(url: source, locale: locale) { status in
                    Task { @MainActor in busy = status }
                }
                try model.store.save(transcript: segments, in: record)
                transcript = segments
                busy = L("Writing notes…")
                let generated = await NoteGenerator.generate(transcript: segments, manualNotes: manualNotes, locale: locale)
                try model.store.save(notes: generated, in: record)
                model.store.writeMarkdown(for: record)
                notes = generated
            } catch {
                model.recorder.errorMessage = error.localizedDescription
            }
            busy = nil
        }
    }
}

private struct Block<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
    }
}

private struct Bullets: View {
    let title: String
    let items: [String]
    var checkbox = false

    var body: some View {
        if !items.isEmpty {
            Block(title: title) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items, id: \.self) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: checkbox ? "circle" : "circle.fill")
                                .font(.system(size: checkbox ? 11 : 5))
                                .foregroundStyle(.secondary)
                            Text(item).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Audio player (plain AVPlayer, no AVKit views)

@MainActor
@Observable
final class AudioPlayer {
    private(set) var isPlaying = false
    private(set) var current: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private var player: AVPlayer?
    private var observer: Any?

    func load(_ url: URL) {
        stop()
        let player = AVPlayer(url: url)
        self.player = player
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let item = self.player?.currentItem else { return }
                self.current = time.seconds
                let total = item.duration.seconds
                if total.isFinite { self.duration = total }
                if self.isPlaying, self.duration > 0, self.current >= self.duration - 0.05 {
                    self.isPlaying = false
                    self.player?.seek(to: .zero)
                }
            }
        }
        Task {
            if let total = try? await AVURLAsset(url: url).load(.duration).seconds, total.isFinite {
                duration = total
            }
        }
    }

    func toggle() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        current = max(0, seconds)
        player.seek(to: CMTime(seconds: current, preferredTimescale: 600))
        if !isPlaying {
            player.play()
            isPlaying = true
        }
    }

    func stop() {
        player?.pause()
        if let observer { player?.removeTimeObserver(observer) }
        observer = nil
        player = nil
        isPlaying = false
    }
}

struct AudioPlayerBar: View {
    let player: AudioPlayer

    var body: some View {
        HStack(spacing: 12) {
            Button(action: player.toggle) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 34, height: 34)
                    .background(.tint.opacity(0.15), in: Circle())
            }
            .buttonStyle(.plain)
            Slider(
                value: Binding(get: { min(player.current, max(player.duration, 0.01)) }, set: { player.seek(to: $0) }),
                in: 0...max(player.duration, 0.01)
            )
            Text("\(player.current.clockString) / \(player.duration.clockString)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 90, alignment: .trailing)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
