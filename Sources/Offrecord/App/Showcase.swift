import AppKit
import SwiftUI

/// `--showcase <out-dir> -storagePath <empty-dir>` creates sample sessions (English transcript,
/// notes from the real note generator) and renders the README screenshots.
@MainActor
enum Showcase {
    static func run(outputDirectory: URL) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = AppModel.shared
        let store = model.store
        guard store.sessions.isEmpty else {
            print("refusing to run: storage folder is not empty (\(store.rootURL.path)). Pass -storagePath <empty-dir>.")
            return
        }
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let main = makeSession(
            title: "Product sync – Q3 launch", kind: .onlineMeeting, minutesAgo: 35, duration: 1_712,
            attendees: ["Sarah Chen", "Alex Kim", "You"], othersName: nil, transcript: productSync,
            manualNotes: [ManualNote(at: 412, text: "Pricing page needs legal review"), ManualNote(at: 905, text: "Beta feedback summary", isBookmark: true)]
        )
        _ = makeSession(title: "1:1 with Alex", kind: .inPerson, minutesAgo: 60 * 26, duration: 1_260,
                        attendees: nil, othersName: nil, transcript: oneOnOne, manualNotes: [])
        _ = makeSession(title: "Customer call – onboarding feedback", kind: .call, minutesAgo: 60 * 27, duration: 980,
                        attendees: nil, othersName: "Maria", transcript: customerCall, manualNotes: [])
        store.reload()

        guard let record = store.record(id: main) else { return }
        model.selectedSessionID = record.id
        render(window(SessionDetailView(record: record)), name: "detail", to: outputDirectory)
        model.selectedSessionID = nil
        model.showTasks = true
        render(window(TasksView()), name: "tasks", to: outputDirectory)
        model.showTasks = false
        render(window(StartView()), name: "start", to: outputDirectory)
        model.recorder.loadPreviewState()
        render(window(RecordingView()), name: "recording", to: outputDirectory)
        render(RecordingPill().environment(model).frame(width: 560, height: 52).padding(14), name: "pill", size: NSSize(width: 588, height: 80), to: outputDirectory)
        print("showcase written to \(outputDirectory.path)")
    }

    // MARK: Sample data

    private static func makeSession(title: String, kind: SessionKind, minutesAgo: Double, duration: TimeInterval,
                                    attendees: [String]?, othersName: String?, transcript: [(Speaker, String)],
                                    manualNotes: [ManualNote]) -> UUID {
        var meta = SessionMeta(id: UUID(), title: title, kind: kind, startedAt: Date().addingTimeInterval(-minutesAgo * 60),
                               duration: duration, options: kind.defaultOptions, localeIdentifier: "en_US")
        meta.isComplete = true
        meta.attendees = attendees
        meta.othersName = othersName
        meta.audioEnhanced = true
        let step = duration / Double(max(transcript.count, 1))
        let segments = transcript.enumerated().map { index, line in
            TranscriptSegment(speaker: line.0, start: Double(index) * step, end: Double(index) * step + step * 0.8, text: line.1)
        }
        guard let record = try? AppModel.shared.store.createFolder(for: meta) else { return meta.id }
        try? AppModel.shared.store.save(meta: meta, in: record)
        try? AppModel.shared.store.save(transcript: segments, in: record)
        try? AppModel.shared.store.save(manualNotes: manualNotes, in: record)

        var notes: GeneratedNotes?
        Task { notes = await NoteGenerator.generate(transcript: segments, manualNotes: manualNotes, locale: Locale(identifier: "en_US")) }
        while notes == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if let notes { try? AppModel.shared.store.save(notes: notes, in: record) }
        AppModel.shared.store.writeMarkdown(for: record)
        return meta.id
    }

    private static let productSync: [(Speaker, String)] = [
        (.others, "Thanks for joining. Today we need to lock the launch date and close the open items for the Q3 release."),
        (.me, "The new onboarding flow is finished and the design team signed off on it yesterday."),
        (.others, "Great. Beta feedback was mostly positive, but users still find the pricing page confusing."),
        (.me, "I will rewrite the pricing copy and share a draft by Thursday."),
        (.others, "We decided to launch on September 12 instead of the first week of September."),
        (.me, "That gives QA one more week, which we really need for the export feature."),
        (.others, "Alex will fix the remaining export bugs by Friday."),
        (.me, "We agreed to keep the free plan, but limit it to three projects."),
        (.others, "Do we need legal to review the new pricing terms before launch?"),
        (.me, "Probably yes. I need to check with legal this week."),
        (.others, "Marketing will prepare the launch email and the blog post next week."),
        (.me, "What about the Android version? Should we announce it at launch or wait?"),
        (.others, "Let's go with a short teaser and announce the full Android release in October."),
        (.me, "Sounds good. I'll send the meeting notes and the updated launch checklist after this call."),
    ]

    private static let oneOnOne: [(Speaker, String)] = [
        (.room, "How is the export feature going? Last week you mentioned some performance problems."),
        (.room, "Large projects take almost a minute to export, so I want to move the work to a background queue."),
        (.room, "Makes sense. We agreed that performance matters more than new formats for this release."),
        (.room, "I will have a first version of the background export ready by Wednesday."),
        (.room, "Do you need help from the backend team for the queue?"),
    ]

    private static let customerCall: [(Speaker, String)] = [
        (.others, "Setting up the workspace was easy, but inviting my team took longer than expected."),
        (.me, "Thanks, that is really helpful. Which step was the slowest for you?"),
        (.others, "Finding the invite button. I expected it on the dashboard, not in settings."),
        (.me, "We will move the invite button to the dashboard in the next update."),
        (.others, "Could you also send me the guide for connecting our calendar?"),
        (.me, "Sure, I will send the calendar guide today."),
    ]

    // MARK: Rendering

    /// Sidebar + detail, like the main window.
    private static func window<Detail: View>(_ detail: Detail) -> some View {
        HStack(spacing: 0) {
            ShowcaseSidebar()
                .frame(width: 260)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        }
        .environment(AppModel.shared)
    }

    private static func render<V: View>(_ view: V, name: String, size: NSSize = NSSize(width: 1200, height: 760), to directory: URL) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name).png"))
        print("rendered \(name)")
    }
}

private struct ShowcaseSidebar: View {
    @State private var search = ""
    var body: some View { SessionList(search: $search) }
}
