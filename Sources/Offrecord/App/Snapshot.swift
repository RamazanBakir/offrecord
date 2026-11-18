import AppKit
import SwiftUI

/// `--snapshot <out-dir>` renders the main screens off-screen to PNG files.
/// Used to check layout and catch view-construction crashes without a display.
@MainActor
enum Snapshot {
    static func run(outputDirectory: URL) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let model = AppModel.shared

        render(ContentView().environment(model), name: "home", to: outputDirectory)
        model.permissionIssue = .screen
        render(ContentView().environment(model), name: "home-permission", to: outputDirectory)
        model.permissionIssue = nil
        for (index, record) in model.store.sessions.prefix(3).enumerated() {
            model.selectedSessionID = record.id
            render(ContentView().environment(model), name: "detail-\(index)", to: outputDirectory)
        }
        model.selectedSessionID = nil
        model.showTasks = true
        render(ContentView().environment(model), name: "tasks", to: outputDirectory)
        model.showTasks = false
        if let first = model.store.sessions.first {
            print("search 'cumaya':", model.store.matches(first, query: "cumaya"), "snippet:", model.store.snippet(first, query: "cumaya") ?? "-")
            print("search 'olmayan':", model.store.matches(first, query: "zzolmayan"))
            if let item = model.store.notes(for: first)?.actionItems.first {
                model.store.toggleAction(item, in: first)
                let onDisk = try? JSONDecoder().decode(GeneratedNotes.self, from: Data(contentsOf: first.folder.appending(path: SessionFiles.notes)))
                print("toggle -> done on disk:", onDisk?.isDone(item) ?? false, "| md:", (try? String(contentsOf: first.markdownURL, encoding: .utf8))?.contains("- [x]") ?? false)
                model.store.toggleAction(item, in: first)
            }
        }
        model.recorder.loadPreviewState()
        render(ContentView().environment(model), name: "recording", to: outputDirectory)
        render(RecordingPill().environment(model), name: "pill", size: NSSize(width: 580, height: 72), to: outputDirectory)
        model.recorder.errorMessage = nil
        render(SessionListPreview().environment(model), name: "sidebar", size: NSSize(width: 280, height: 400), to: outputDirectory)
        render(SettingsView().environment(model), name: "settings", size: NSSize(width: 520, height: 420), to: outputDirectory)
        print("snapshots written to \(outputDirectory.path)")
    }

    /// `--delete-test <out-dir>`: creates two sessions, deletes one through the UI path, checks the list.
    static func deleteTest(outputDirectory: URL) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = AppModel.shared
        let store = model.store
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        for title in ["Silinecek kayıt", "Kalacak kayıt"] {
            let meta = SessionMeta(id: UUID(), title: title, kind: .onlineMeeting, startedAt: .now, duration: 5,
                                   options: SessionKind.onlineMeeting.defaultOptions, localeIdentifier: "tr_TR")
            if let record = try? store.createFolder(for: meta) { try? store.save(transcript: [], in: record) }
        }
        store.reload()
        print("before:", store.sessions.map(\.meta.title))
        // One persistent host, like the real window.
        let size = NSSize(width: 280, height: 300)
        let host = NSHostingView(rootView: SessionListPreview().environment(model).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        func capture(_ name: String) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: outputDirectory.appending(path: "\(name).png"))
            }
        }
        guard let victim = store.sessions.first(where: { $0.meta.title == "Silinecek kayıt" }) else { return }
        model.selectedSessionID = victim.id
        capture("live-before")
        model.pendingDelete = victim
        model.confirmDelete()
        print("selected after delete:", model.selectedSessionID as Any, "error:", model.recorder.errorMessage as Any)
        print("after store:", store.sessions.map(\.meta.title))
        capture("live-after")
        store.reload()
        print("after reload:", store.sessions.map(\.meta.title))
    }

    private static func render<V: View>(_ view: V, name: String, size: NSSize = NSSize(width: 960, height: 640), to directory: URL) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name).png"))
        print("rendered \(name)")
    }
}

private struct SessionListPreview: View {
    @State private var search = ""
    var body: some View { SessionList(search: $search) }
}
