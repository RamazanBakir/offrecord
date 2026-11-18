import SwiftUI

/// Live session: timer + stop on top, flowing transcript, note field at the bottom.
struct RecordingView: View {
    @Environment(AppModel.self) private var model
    @State private var noteText = ""
    @FocusState private var noteFocused: Bool

    private var recorder: RecordingController { model.recorder }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if case .recording = recorder.phase {
                timeline
                Divider()
                noteField
            } else {
                progress
            }
        }
        .onAppear { noteFocused = true }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if recorder.isRecording {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    HStack(spacing: 8) {
                        Circle().fill(recorder.isPaused ? .orange : .red).frame(width: 10, height: 10)
                        Text(recorder.isPaused ? L("Paused") : recorder.elapsed.clockString)
                            .font(.title2.monospacedDigit().weight(.semibold))
                    }
                }
                LevelBars(levels: recorder.levels, hasRemote: recorder.meta?.options.systemAudio == true)
            }
            Text(recorder.meta?.title ?? "")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if recorder.isRecording {
                Button {
                    recorder.togglePause()
                } label: {
                    Label(recorder.isPaused ? L("Resume") : L("Pause"), systemImage: recorder.isPaused ? "play.fill" : "pause.fill")
                }
                .controlSize(.large)
                .help(L("Pause / resume (⇧⌘P)"))
                Button {
                    model.stop()
                } label: {
                    Label(L("Stop"), systemImage: "stop.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var progress: some View {
        VStack(spacing: 12) {
            ProgressView()
            switch recorder.phase {
            case .preparing(let status), .finishing(let status):
                Text(status).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Transcript and own notes merged in time order.
    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if recorder.remoteSideSilent {
                        RemoteSilentWarning()
                    }
                    if let warning = recorder.liveTranscriptionWarning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    if items.isEmpty, recorder.volatileText.isEmpty {
                        Text(L("Listening… The conversation will be transcribed here."))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                    ForEach(items) { item in
                        switch item {
                        case .segment(let segment): SegmentRow(segment: segment, label: recorder.meta?.label(for: segment.speaker))
                        case .note(let note): NoteRow(note: note)
                        }
                    }
                    ForEach(Array(recorder.volatileText.keys), id: \.self) { speaker in
                        if let text = recorder.volatileText[speaker] {
                            SegmentRow(
                                segment: TranscriptSegment(speaker: speaker, start: recorder.elapsed, end: recorder.elapsed, text: text),
                                volatile: true
                            )
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(20)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: items.count) {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: recorder.volatileText) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var noteField: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil")
                .foregroundStyle(.secondary)
            TextField(L("Type a note and press Enter…"), text: $noteText)
                .textFieldStyle(.plain)
                .focused($noteFocused)
                .onSubmit {
                    recorder.addNote(noteText)
                    noteText = ""
                }
            Button {
                recorder.addBookmark()
            } label: {
                Image(systemName: "star")
            }
            .buttonStyle(.borderless)
            .help(L("Mark this moment as important (⌘B)"))
            HStack(spacing: 6) {
                KeyCap("⌘B")
                Text(L("mark")).font(.caption).foregroundStyle(.secondary)
                KeyCap("⌘.")
                Text(L("stop")).font(.caption).foregroundStyle(.secondary)
                KeyCap("⌃⌥R")
                Text(L("anywhere")).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.leading, 8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var items: [TimelineItem] {
        (recorder.segments.map(TimelineItem.segment) + recorder.manualNotes.map(TimelineItem.note))
            .sorted { $0.time < $1.time }
    }
}

enum TimelineItem: Identifiable {
    case segment(TranscriptSegment)
    case note(ManualNote)

    var id: UUID {
        switch self {
        case .segment(let s): s.id
        case .note(let n): n.id
        }
    }

    var time: TimeInterval {
        switch self {
        case .segment(let s): s.start
        case .note(let n): n.at
        }
    }
}

struct SegmentRow: View {
    let segment: TranscriptSegment
    var label: String?
    var volatile = false
    var onTap: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label ?? segment.speaker.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                Text(segment.start.clockString)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Text(segment.text)
                .foregroundStyle(volatile ? .secondary : .primary)
                .textSelection(.enabled)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }

    private var color: Color {
        switch segment.speaker {
        case .me: .blue
        case .others: .purple
        case .room: .teal
        }
    }
}

struct NoteRow: View {
    let note: ManualNote
    var onTap: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: note.isBookmark ? "star.fill" : "pencil")
                .foregroundStyle(note.isBookmark ? .yellow : .orange)
                .font(.caption)
            Text(note.text)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Text(note.at.clockString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}

/// Two tiny live meters: microphone and remote side. Proves audio is coming in.
struct LevelBars: View {
    let levels: [Speaker: Float]
    let hasRemote: Bool

    var body: some View {
        HStack(spacing: 8) {
            meter(levels[.me] ?? levels[.room] ?? 0, symbol: "mic.fill", help: L("Microphone"))
            if hasRemote {
                meter(levels[.others] ?? 0, symbol: "speaker.wave.2.fill", help: L("Them"))
            }
        }
    }

    private func meter(_ level: Float, symbol: String, help: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.green.gradient)
                    .frame(width: 34 * CGFloat(max(0.04, level)))
            }
            .frame(width: 34, height: 5)
            .animation(.linear(duration: 0.1), value: level)
        }
        .help(help)
    }
}

struct RemoteSilentWarning: View {
    var body: some View {
        Label {
            Text(L("No sound from the other side. Is the call running on this Mac? Is the right audio output (speakers/headphones) selected?"))
        } icon: {
            Image(systemName: "speaker.slash")
        }
        .font(.callout)
        .foregroundStyle(.orange)
    }
}
