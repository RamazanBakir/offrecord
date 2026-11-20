import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SessionList(search: $search)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let release = model.updates.available { UpdateBanner(release: release) }
                }
        }
        .onAppear { model.openWindowAction = openWindow }
        .confirmationDialog(
            L("Move “%@” to the Trash?", model.pendingDelete?.meta.title ?? ""),
            isPresented: Binding(get: { model.pendingDelete != nil }, set: { if !$0 { model.pendingDelete = nil } })
        ) {
            Button(L("Move to Trash"), role: .destructive) { model.confirmDelete() }
            Button(L("Cancel"), role: .cancel) { model.pendingDelete = nil }
        }
        .alert(L("Something went wrong"), isPresented: Binding(
            get: { model.recorder.errorMessage != nil },
            set: { if !$0 { model.recorder.errorMessage = nil } }
        )) {
            if model.recorder.errorMessage?.contains(L("Screen & System Audio Recording")) == true {
                Button(L("Open Settings")) { SystemAudioCapture.openPrivacySettings() }
            }
            Button(L("OK"), role: .cancel) {}
        } message: {
            Text(model.recorder.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if model.recorder.isActive, model.selectedSessionID == nil {
            RecordingView()
        } else if let record = model.store.record(id: model.selectedSessionID) {
            SessionDetailView(record: record)
                .id(record.id)
        } else if model.showTasks {
            TasksView()
        } else {
            StartView()
        }
    }
}

// MARK: - Update banner

struct UpdateBanner: View {
    @Environment(AppModel.self) private var model
    let release: UpdateChecker.Release

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Offrecord %@ is available", release.version)).font(.headline)
                Text(L("You have version %@.", AppInfo.version)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(L("Skip this version")) { model.updates.skipAvailable() }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            Button(L("Later")) { model.updates.dismissForNow() }
            Button(L("Get update")) { NSWorkspace.shared.open(release.pageURL) }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

// MARK: - Sidebar

struct SessionList: View {
    @Environment(AppModel.self) private var model
    @Binding var search: String

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedSessionID) {
            Button {
                model.selectedSessionID = nil
                model.showTasks = false
            } label: {
                Label(
                    model.recorder.isActive ? L("Recording…") : L("New recording"),
                    systemImage: model.recorder.isActive ? "record.circle.fill" : "plus.circle"
                )
                .foregroundStyle(model.recorder.isActive ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                .font(.body.weight(.medium))
            }
            .buttonStyle(.plain)
            .padding(.vertical, 4)

            Button {
                model.selectedSessionID = nil
                model.showTasks = true
            } label: {
                HStack {
                    Label(L("To-dos"), systemImage: "checklist")
                    Spacer()
                    let open = TaskItem.all(in: model.store).filter { !$0.done }.count
                    if open > 0 {
                        Text("\(open)")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(.tint.opacity(0.18), in: Capsule())
                    }
                }
                .font(.body.weight(.medium))
                .foregroundStyle(model.showTasks && model.selectedSessionID == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.bottom, 4)

            if let status = model.importStatus {
                Label(status, systemImage: "arrow.down.doc")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.records) { record in
                        SessionRow(record: record, snippet: search.isEmpty ? nil : model.store.snippet(record, query: search))
                            .tag(record.id)
                            .contextMenu {
                                Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([record.folder]) }
                                Divider()
                                Button(L("Delete…"), role: .destructive) { model.pendingDelete = record }
                            }
                    }
                }
            }
        }
        .searchable(text: $search, placement: .sidebar, prompt: L("Search titles, notes and transcripts"))
        .onChange(of: model.selectedSessionID) { if model.selectedSessionID != nil { model.showTasks = false } }
    }

    private var groups: [(title: String, records: [SessionRecord])] {
        let records = search.isEmpty
            ? model.store.sessions
            : model.store.sessions.filter { model.store.matches($0, query: search) }
        let calendar = Calendar.current
        var result: [(title: String, records: [SessionRecord])] = []
        for record in records {
            let date = record.meta.startedAt
            let title = calendar.isDateInToday(date) ? L("Today")
                : calendar.isDateInYesterday(date) ? L("Yesterday")
                : date.formatted(.dateTime.locale(AppLanguage.current.locale).day().month(.wide).year())
            if result.last?.title == title {
                result[result.count - 1].records.append(record)
            } else {
                result.append((title, [record]))
            }
        }
        return result
    }
}

struct SessionRow: View {
    let record: SessionRecord
    var snippet: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.meta.title)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(record.meta.startedAt.formatted(date: .omitted, time: .shortened))
                Text("·")
                Text(record.meta.duration.clockString)
                if record.meta.options.screen {
                    Image(systemName: "display")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let snippet {
                Text("…\(snippet)…")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Start screen

struct StartView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 28) {
            Spacer()

            Button {
                model.start()
            } label: {
                ZStack {
                    Circle()
                        .fill(.red.gradient)
                        .frame(width: 104, height: 104)
                        .shadow(color: .red.opacity(0.35), radius: 14, y: 4)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .help(L("Start recording (⌃⌥R)"))

            VStack(spacing: 6) {
                Text(L("Start recording"))
                    .font(.title2.weight(.semibold))
                Text(L("When you stop, the summary, decisions and to-dos are ready."))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                Picker("", selection: Binding(get: { model.mode }, set: { model.mode = $0; model.permissionIssue = nil })) {
                    ForEach(RecordMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 360)

                Text(model.mode.hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Toggle(L("Also record the screen"), isOn: $model.recordScreen)
                        .toggleStyle(.checkbox)
                    if model.recordScreen, let last = model.lastScreenTarget {
                        Picker("", selection: $model.reuseLastScreen) {
                            Text(L("Choose when recording starts")).tag(false)
                            Text(last.label).tag(true)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
            }

            if let issue = model.permissionIssue {
                PermissionCard(issue: issue)
            }

            Spacer()

            ShortcutLegend()
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

struct PermissionCard: View {
    @Environment(AppModel.self) private var model
    let issue: PermissionIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(issue.title, systemImage: "lock.shield")
                .font(.headline)
            Text(issue.steps)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("Open Settings")) { issue.openSettings() }
                if issue == .screen {
                    Button(L("Restart the app")) { model.relaunch() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 440, alignment: .leading)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Every shortcut in one compact block, shown at the bottom of the start screen.
struct ShortcutLegend: View {
    static var items: [(keys: String, action: String)] { [
        ("⌃⌥R", L("Start / stop recording from anywhere")),
        ("⌘.", L("Stop recording")),
        ("⌘B", L("Mark important moment")),
        ("⇧⌘P", L("Pause / resume")),
        ("↩", L("Add note (while recording)")),
        ("⌘O", L("Transcribe an audio / video file")),
        ("⌘⌫", L("Delete selected recording")),
        ("⌘,", L("Settings")),
        (L("Click / right-click"), L("Menu bar: start-stop / menu")),
    ] }

    var body: some View {
        VStack(spacing: 8) {
            Text(L("Shortcuts"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                ForEach(0..<(Self.items.count + 1) / 2, id: \.self) { row in
                    GridRow {
                        cell(Self.items[row * 2])
                        if row * 2 + 1 < Self.items.count { cell(Self.items[row * 2 + 1]) }
                    }
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func cell(_ item: (keys: String, action: String)) -> some View {
        KeyCap(item.keys)
            .gridColumnAlignment(.trailing)
        Text(item.action)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.trailing, 14)
    }
}

struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.monospaced().weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.background, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
    }
}
