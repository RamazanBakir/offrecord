import Foundation

/// What kind of session is being recorded. Each kind picks sensible capture defaults.
enum SessionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case onlineMeeting
    case call
    case inPerson
    case screenSession
    case voiceMemo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onlineMeeting: L("Online meeting")
        case .call: L("Call")
        case .inPerson: L("In-person meeting")
        case .screenSession: L("Screen recording")
        case .voiceMemo: L("Voice memo")
        }
    }

    var subtitle: String {
        switch self {
        case .onlineMeeting: L("Zoom, Meet, Teams… System audio + microphone")
        case .call: L("WhatsApp, FaceTime, phone (via your Mac)")
        case .inPerson: L("Conversation in the same room, microphone only")
        case .screenSession: L("Screen + audio, demo or tutorial")
        case .voiceMemo: L("Notes to self, ideas, to-dos")
        }
    }

    var symbol: String {
        switch self {
        case .onlineMeeting: "video"
        case .call: "phone"
        case .inPerson: "person.2"
        case .screenSession: "rectangle.dashed.badge.record"
        case .voiceMemo: "mic"
        }
    }

    var defaultOptions: CaptureOptions {
        switch self {
        case .onlineMeeting: CaptureOptions(systemAudio: true, microphone: true, screen: false, transcribe: true)
        case .call: CaptureOptions(systemAudio: true, microphone: true, screen: false, transcribe: true)
        case .inPerson: CaptureOptions(systemAudio: false, microphone: true, screen: false, transcribe: true)
        case .screenSession: CaptureOptions(systemAudio: true, microphone: true, screen: true, transcribe: true)
        case .voiceMemo: CaptureOptions(systemAudio: false, microphone: true, screen: false, transcribe: true)
        }
    }

    /// Whether the microphone channel carries every speaker (no separate remote channel).
    var micIsWholeRoom: Bool { self == .inPerson || self == .voiceMemo }
}

/// The two choices offered on the start screen.
enum RecordMode: String, CaseIterable, Identifiable {
    case computer
    case inPerson

    var id: String { rawValue }

    var title: String {
        switch self {
        case .computer: L("Online meeting / call")
        case .inPerson: L("In person")
        }
    }

    var hint: String {
        switch self {
        case .computer: L("Records the other side (Zoom, Meet, WhatsApp…) and your voice.")
        case .inPerson: L("Records the conversation in the room with the microphone.")
        }
    }

    func options(recordScreen: Bool) -> (SessionKind, CaptureOptions) {
        switch self {
        case .computer:
            (recordScreen ? .screenSession : .onlineMeeting,
             CaptureOptions(systemAudio: true, microphone: true, screen: recordScreen, transcribe: true))
        case .inPerson:
            (.inPerson, CaptureOptions(systemAudio: false, microphone: true, screen: recordScreen, transcribe: true))
        }
    }
}

struct CaptureOptions: Codable, Hashable, Sendable {
    var systemAudio: Bool
    var microphone: Bool
    var screen: Bool
    var transcribe: Bool
}

enum Speaker: String, Codable, Sendable {
    case me
    case others
    case room

    var label: String {
        switch self {
        case .me: L("Me")
        case .others: L("Them")
        case .room: L("Conversation")
        }
    }
}

struct TranscriptSegment: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var speaker: Speaker
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

struct ManualNote: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var at: TimeInterval
    var text: String
    var isBookmark = false
}

struct GeneratedNotes: Codable, Hashable, Sendable {
    var summary: [String]
    var keyPoints: [String]
    var decisions: [String]
    var actionItems: [String]
    var questions: [String]
    var engine: String
    var createdAt: Date
    /// Action items the user ticked off.
    var completedActions: [String]?

    func isDone(_ item: String) -> Bool { completedActions?.contains(item) == true }

    var isEmpty: Bool {
        summary.isEmpty && keyPoints.isEmpty && decisions.isEmpty && actionItems.isEmpty && questions.isEmpty
    }
}

struct SessionMeta: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    var kind: SessionKind
    var startedAt: Date
    var duration: TimeInterval
    var options: CaptureOptions
    var localeIdentifier: String
    /// false while recording; stays false if the app died mid-recording (recovered on next launch).
    var isComplete: Bool?
    /// Participants from the calendar event, if any.
    var attendees: [String]?
    /// Display name for the remote side (L("Them") by default).
    var othersName: String?
    /// True once speech leveling was applied to audio.m4a.
    var audioEnhanced: Bool?

    func label(for speaker: Speaker) -> String {
        if speaker == .others, let name = othersName, !name.isEmpty { return name }
        return speaker.label
    }
}

/// A session on disk: metadata plus the folder that holds its files.
struct SessionRecord: Identifiable, Hashable {
    var meta: SessionMeta
    var folder: URL

    var id: UUID { meta.id }

    var audioURL: URL { folder.appending(path: SessionFiles.audio) }
    var screenURL: URL { folder.appending(path: SessionFiles.screen) }
    var markdownURL: URL { folder.appending(path: SessionFiles.markdown) }

    var hasAudio: Bool { FileManager.default.fileExists(atPath: audioURL.path) }
    var hasScreen: Bool { FileManager.default.fileExists(atPath: screenURL.path) }
}

enum SessionFiles {
    static let meta = "meta.json"
    static let transcript = "transcript.json"
    static let manualNotes = "manual-notes.json"
    static let notes = "notes.json"
    static let markdown = "notes.md"
    static let audio = "audio.m4a"
    // Crash-safe intermediate files (PCM CAF stays readable if the app dies mid-recording).
    static let micAudio = "mic.caf"
    static let systemAudio = "system.caf"
    static let screen = "screen.mov"
    // Screen video is recorded in parts (pausing closes one) and assembled into screen.mov.
    static let screenParts = "screen-parts.json"
    static let screenPartPrefix = "screen-part-"
    static func screenPart(_ number: Int) -> String { "\(screenPartPrefix)\(number).mov" }
}

extension TimeInterval {
    /// 75 -> "01:15", 3725 -> "1:02:05"
    var clockString: String {
        let total = Int(self.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}
