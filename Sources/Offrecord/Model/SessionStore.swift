import Foundation
import Observation

/// Reads and writes sessions under the storage folder (default ~/Documents/Offrecord).
@MainActor
@Observable
final class SessionStore {
    static let storagePathKey = "storagePath"

    private(set) var sessions: [SessionRecord] = []
    /// Lower-cased title + notes + transcript per session, for full-text search.
    private var searchIndex: [UUID: String] = [:]
    @ObservationIgnored private var notesCache: [UUID: GeneratedNotes] = [:]

    var rootURL: URL {
        if let custom = UserDefaults.standard.string(forKey: Self.storagePathKey), !custom.isEmpty {
            return URL(filePath: custom, directoryHint: .isDirectory)
        }
        return URL.documentsDirectory.appending(path: "Offrecord", directoryHint: .isDirectory)
    }

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        removeAbandonedFolders()
        reload()
    }

    /// Deletes folders left behind by recordings that never started (e.g. the app
    /// was restarted while a permission prompt was open): they hold only meta.json.
    private func removeAbandonedFolders() {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            let contents = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            if contents == [SessionFiles.meta] {
                try? fm.removeItem(at: folder)
            }
        }
    }

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let folders = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        sessions = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: SessionFiles.meta)),
                  let meta = try? decoder.decode(SessionMeta.self, from: data) else { return nil }
            return SessionRecord(meta: meta, folder: folder)
        }
        .sorted { $0.meta.startedAt > $1.meta.startedAt }
        rebuildSearchIndex()
    }

    private func rebuildSearchIndex() {
        notesCache = [:]
        var index: [UUID: String] = [:]
        for record in sessions {
            var parts = [record.meta.title] + (record.meta.attendees ?? [])
            if let notes = notes(for: record) {
                parts += notes.summary + notes.actionItems + notes.decisions + notes.questions + notes.keyPoints
            }
            parts += manualNotes(for: record).map(\.text)
            parts += transcript(for: record).map(\.text)
            index[record.id] = parts.joined(separator: "\n").lowercased(with: Locale(identifier: "tr_TR"))
        }
        searchIndex = index
    }

    func matches(_ record: SessionRecord, query: String) -> Bool {
        let q = query.lowercased(with: Locale(identifier: "tr_TR"))
        return searchIndex[record.id]?.contains(q) ?? record.meta.title.localizedCaseInsensitiveContains(query)
    }

    /// The line that matched, shown under the session in search results.
    func snippet(_ record: SessionRecord, query: String) -> String? {
        let q = query.lowercased(with: Locale(identifier: "tr_TR"))
        guard let text = searchIndex[record.id] else { return nil }
        return text.split(separator: "\n").first { $0.contains(q) && !record.meta.title.lowercased(with: Locale(identifier: "tr_TR")).contains($0) }
            .map { String($0.prefix(90)) }
    }

    /// Ticks / unticks an action item and saves it.
    func toggleAction(_ item: String, in record: SessionRecord) {
        guard var notes = notes(for: record) else { return }
        var done = Set(notes.completedActions ?? [])
        if done.contains(item) { done.remove(item) } else { done.insert(item) }
        notes.completedActions = Array(done)
        try? save(notes: notes, in: record)
        writeMarkdown(for: record)
        actionsVersion += 1
    }

    /// Bumped whenever action items change so task views refresh.
    private(set) var actionsVersion = 0

    var unfinished: [SessionRecord] {
        sessions.filter { $0.meta.isComplete == false }
    }

    func record(id: UUID?) -> SessionRecord? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    /// Creates the folder for a new session and writes its initial metadata.
    func createFolder(for meta: SessionMeta) throws -> SessionRecord {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safeTitle = meta.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: ".")
            .prefix(60)
        let folder = rootURL.appending(path: "\(formatter.string(from: meta.startedAt)) \(safeTitle)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record = SessionRecord(meta: meta, folder: folder)
        try save(meta: meta, in: record)
        return record
    }

    func save(meta: SessionMeta, in record: SessionRecord) throws {
        try write(meta, to: record.folder.appending(path: SessionFiles.meta))
        if let index = sessions.firstIndex(where: { $0.id == meta.id }) {
            sessions[index].meta = meta
        }
    }

    func save(transcript: [TranscriptSegment], in record: SessionRecord) throws {
        try write(transcript, to: record.folder.appending(path: SessionFiles.transcript))
    }

    func save(manualNotes: [ManualNote], in record: SessionRecord) throws {
        try write(manualNotes, to: record.folder.appending(path: SessionFiles.manualNotes))
    }

    func save(notes: GeneratedNotes, in record: SessionRecord) throws {
        notesCache[record.id] = notes
        try write(notes, to: record.folder.appending(path: SessionFiles.notes))
    }

    func transcript(for record: SessionRecord) -> [TranscriptSegment] {
        read([TranscriptSegment].self, from: record.folder.appending(path: SessionFiles.transcript)) ?? []
    }

    func manualNotes(for record: SessionRecord) -> [ManualNote] {
        read([ManualNote].self, from: record.folder.appending(path: SessionFiles.manualNotes)) ?? []
    }

    func notes(for record: SessionRecord) -> GeneratedNotes? {
        if let cached = notesCache[record.id] { return cached }
        let notes = read(GeneratedNotes.self, from: record.folder.appending(path: SessionFiles.notes))
        notesCache[record.id] = notes
        return notes
    }

    /// Re-renders notes.md from everything stored for the session.
    func writeMarkdown(for record: SessionRecord) {
        let record = self.record(id: record.id) ?? record
        let markdown = MarkdownRenderer.render(
            meta: record.meta,
            notes: notes(for: record),
            manualNotes: manualNotes(for: record),
            transcript: transcript(for: record)
        )
        try? markdown.write(to: record.markdownURL, atomically: true, encoding: .utf8)
    }

    /// Moves the session folder to the Trash (recoverable).
    func moveToTrash(_ record: SessionRecord) throws {
        // Always resync with disk: trashItem can report an error even after the move happened.
        defer { reload() }
        do {
            try FileManager.default.trashItem(at: record.folder, resultingItemURL: nil)
        } catch {
            if FileManager.default.fileExists(atPath: record.folder.path) { throw error }
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
