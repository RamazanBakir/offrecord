import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers
import Observation
@preconcurrency import ScreenCaptureKit
import SwiftUI
import UserNotifications

enum SettingsKeys {
    static let localeIdentifier = "localeIdentifier"
    static let detectMeetings = "detectMeetings"
    static let recordMode = "recordMode"
    static let recordScreen = "recordScreen"
    static let reuseLastScreen = "reuseLastScreen"
    static let lastScreenTarget = "lastScreenTarget"
    static let useCalendar = "useCalendar"
    static let voiceProcessing = "voiceProcessing"
    static let autoStopOnCallEnd = "autoStopOnCallEnd"

    /// Transcription language when none was chosen: the system language
    /// (read from global preferences, since the app's own AppleLanguages follows the UI language).
    static var defaultSpeechLocale: String {
        let global = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
        return (global?.first ?? "en-US").replacingOccurrences(of: "-", with: "_")
    }
}

/// App-wide state shared by the main window, the menu bar item and the app delegate.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let store: SessionStore
    let recorder: RecordingController
    var selectedSessionID: UUID?
    var importStatus: String?

    var mode: RecordMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: SettingsKeys.recordMode) }
    }
    var recordScreen: Bool {
        didSet { UserDefaults.standard.set(recordScreen, forKey: SettingsKeys.recordScreen) }
    }
    /// Record the last chosen display/window again instead of showing the picker.
    var reuseLastScreen: Bool {
        didSet { UserDefaults.standard.set(reuseLastScreen, forKey: SettingsKeys.reuseLastScreen) }
    }
    private(set) var lastScreenTarget: ScreenTarget? {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(lastScreenTarget), forKey: SettingsKeys.lastScreenTarget) }
    }
    /// True while the display/window to record is being chosen.
    private(set) var isChoosingScreen = false
    private let screenPicker = ScreenPicker()

    let detector = MeetingDetector()
    let updates = UpdateChecker()
    private var lastDetectionPrompt = Date.distantPast

    /// Transcription language for new recordings and imports.
    var speechLanguage: SpeechLanguage {
        didSet { SpeechLanguage.saved = speechLanguage }
    }

    private init() {
        UserDefaults.standard.register(defaults: [SettingsKeys.detectMeetings: true, SettingsKeys.useCalendar: true,
                                                  SettingsKeys.voiceProcessing: true, SettingsKeys.autoStopOnCallEnd: true])
        store = SessionStore()
        recorder = RecordingController(store: store)
        mode = RecordMode(rawValue: UserDefaults.standard.string(forKey: SettingsKeys.recordMode) ?? "") ?? .computer
        recordScreen = UserDefaults.standard.bool(forKey: SettingsKeys.recordScreen)
        SpeechLanguage.migrateDefaultChoice()
        speechLanguage = SpeechLanguage.saved
        reuseLastScreen = UserDefaults.standard.bool(forKey: SettingsKeys.reuseLastScreen)
        lastScreenTarget = UserDefaults.standard.data(forKey: SettingsKeys.lastScreenTarget)
            .flatMap { try? JSONDecoder().decode(ScreenTarget.self, from: $0) }
    }

    var showTasks = false

    /// Finishes recordings interrupted by a crash or shutdown: rebuilds the audio
    /// from the crash-safe CAF files and writes notes from the autosaved transcript.
    func recoverUnfinished() {
        let pending = store.unfinished.filter { $0.id != recorder.meta?.id }
        guard !pending.isEmpty else { return }
        Task {
            for record in pending {
                var meta = record.meta
                meta.audioEnhanced = (try? await AudioMerger.finalize(folder: record.folder, into: record.audioURL)) ?? false
                try? await ScreenRecordingAssembler.finalize(folder: record.folder, audio: record.audioURL, into: record.screenURL)
                if let seconds = try? await AVURLAsset(url: record.audioURL).load(.duration).seconds, seconds.isFinite {
                    meta.duration = seconds
                }
                meta.isComplete = true
                meta.title += L(" (recovered)")
                try? store.save(meta: meta, in: record)
                let transcript = store.transcript(for: record)
                let notes = await NoteGenerator.generate(
                    transcript: transcript, manualNotes: store.manualNotes(for: record), locale: Locale(identifier: meta.localeIdentifier)
                )
                try? store.save(notes: notes, in: record)
                store.writeMarkdown(for: record)
            }
            store.reload()
        }
    }

    /// Session waiting for delete confirmation (sidebar, toolbar or ⌘⌫).
    var pendingDelete: SessionRecord?

    func requestDeleteSelected() {
        pendingDelete = store.record(id: selectedSessionID)
    }

    func confirmDelete() {
        guard let record = pendingDelete else { return }
        pendingDelete = nil
        if selectedSessionID == record.id { selectedSessionID = nil }
        do {
            try store.moveToTrash(record)
        } catch {
            recorder.errorMessage = L("Couldn't delete the recording: %@", error.localizedDescription)
        }
    }

    /// Set when a recording could not start because a macOS permission is missing.
    var permissionIssue: PermissionIssue?

    /// Starts a recording with the current choices (or an explicit mode from the menu bar).
    func start(_ requested: RecordMode? = nil) {
        guard !recorder.isActive, !isChoosingScreen else { return }
        if let requested { mode = requested }
        let (kind, options) = mode.options(recordScreen: recordScreen)
        selectedSessionID = nil

        // Check permissions up front so the user gets clear guidance instead of a failed start.
        if options.microphone {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .denied || status == .restricted {
                permissionIssue = .microphone
                return
            }
        }
        if options.systemAudio || options.screen, !CGPreflightScreenCaptureAccess() {
            // Registers the app in System Settings and shows the system prompt once.
            CGRequestScreenCaptureAccess()
            permissionIssue = .screen
            return
        }
        permissionIssue = nil
        let useCalendar = UserDefaults.standard.bool(forKey: SettingsKeys.useCalendar)
        let callApp = detector.activeApps.first
        // Set before the task so a second press cannot open another picker.
        isChoosingScreen = options.screen
        Task {
            var screenFilter: SCContentFilter?
            if options.screen {
                let filter = await chooseScreen()
                isChoosingScreen = false
                guard let filter else { return }
                screenFilter = filter
            }
            let event = useCalendar ? await CalendarLookup.currentEvent() : nil
            // Without a calendar event, name it after the call app ("WhatsApp call").
            let fallbackTitle = callApp.map {
                L("%@ call – %@", $0.name, Date().formatted(.dateTime.locale(AppLanguage.current.locale).day().month(.abbreviated).hour().minute()))
            }
            await recorder.start(
                title: event?.title ?? fallbackTitle, kind: kind, options: options, language: speechLanguage,
                screenFilter: screenFilter, attendees: event?.attendees, othersName: event?.otherPerson
            )
            detector.recordingStarted()
        }
    }

    /// What to record on screen: the last display/window when the user chose to reuse
    /// it and it is still there, otherwise whatever they pick now. Nil when cancelled.
    private func chooseScreen() async -> SCContentFilter? {
        if reuseLastScreen, let last = lastScreenTarget, let filter = try? await last.makeFilter() {
            return filter
        }
        guard let picked = await screenPicker.choose() else { return nil }
        guard let target = ScreenTarget(picked) else { return picked }
        lastScreenTarget = target
        // Rebuilt so Offrecord's own windows stay out of a full-screen recording.
        return (try? await target.makeFilter()) ?? picked
    }

    /// Lets the user pick another display or window while the screen is recorded.
    func changeScreen() {
        guard recorder.canChangeScreen, !isChoosingScreen else { return }
        isChoosingScreen = true
        Task {
            defer { isChoosingScreen = false }
            guard let picked = await screenPicker.choose() else { return }
            let target = ScreenTarget(picked)
            if let target { lastScreenTarget = target }
            let filter = (try? await target?.makeFilter()) ?? picked
            recorder.changeScreen(to: filter, label: target?.label)
        }
    }

    /// Restarts the app (macOS applies a new Screen Recording permission only after a relaunch).
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Imports an existing audio/video file and transcribes it.
    func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        let language = speechLanguage
        importStatus = L("Preparing %@…", url.lastPathComponent)
        Task {
            defer {
                if access { url.stopAccessingSecurityScopedResource() }
                importStatus = nil
            }
            do {
                let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
                var meta = SessionMeta(
                    id: UUID(), title: url.deletingPathExtension().lastPathComponent, kind: .voiceMemo,
                    startedAt: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .now,
                    duration: duration.isFinite ? duration : 0,
                    options: CaptureOptions(systemAudio: false, microphone: false, screen: false, transcribe: true),
                    localeIdentifier: language.candidates[0].identifier
                )
                let record = try store.createFolder(for: meta)
                let isVideo = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
                if isVideo {
                    try FileManager.default.copyItem(at: url, to: record.screenURL)
                }
                try await AudioMerger.extractAudio(from: url, to: record.audioURL)
                let result = try await FileTranscriber.transcribe(url: record.audioURL, language: language) { status in
                    Task { @MainActor in self.importStatus = "\(url.lastPathComponent): \(status)" }
                }
                meta.localeIdentifier = result.locale.identifier
                try store.save(meta: meta, in: record)
                try store.save(transcript: result.segments, in: record)
                let notes = await NoteGenerator.generate(transcript: result.segments, manualNotes: [], locale: result.locale)
                try store.save(notes: notes, in: record)
                store.writeMarkdown(for: record)
                store.reload()
                selectedSessionID = meta.id
            } catch {
                recorder.errorMessage = L("Import failed: %@", error.localizedDescription)
                store.reload()
            }
        }
    }

    /// Captured from the SwiftUI scene so AppKit code (menu bar, hotkey, notifications) can reopen the window.
    @ObservationIgnored var openWindowAction: OpenWindowAction?

    /// One action for every start/stop entry point (hotkey, menu bar click).
    func toggleRecording() {
        if recorder.isRecording {
            stop()
        } else if !recorder.isActive {
            start()
            if permissionIssue != nil { openMainWindow() }
        }
    }

    func stop() {
        guard recorder.isRecording else { return }
        Task {
            await recorder.stop()
            guard let id = recorder.lastFinishedID else { return }
            selectedSessionID = id
            let title = store.record(id: id)?.meta.title ?? L("Recording")
            Notifications.postNotesReady(
                title: stoppedAutomatically ? L("Call ended, recording stopped · %@", title) : title, sessionID: id
            )
            stoppedAutomatically = false
        }
    }

    func openMainWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.title == "Offrecord" && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindowAction?(id: "main")
        }
    }

    // MARK: Meeting detection

    func startMeetingDetection() {
        detector.onCallStarted = { [weak self] app in self?.callStarted(app) }
        detector.onCallEnded = { [weak self] in self?.callEnded() }
        detector.start()
    }

    private func callStarted(_ app: MeetingDetector.CallApp) {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.detectMeetings),
              !recorder.isActive,
              Date().timeIntervalSince(lastDetectionPrompt) > 120 else { return }
        lastDetectionPrompt = Date()
        Notifications.postMeetingDetected(appName: app.name)
    }

    /// The call app released the microphone: the call is over.
    private func callEnded() {
        guard recorder.isRecording,
              recorder.meta?.options.systemAudio == true,
              UserDefaults.standard.bool(forKey: SettingsKeys.autoStopOnCallEnd) else { return }
        // Some apps release the mic on mute: only stop once the remote side is quiet too.
        guard Date().timeIntervalSince(recorder.lastRemoteSoundAt) > 8 else { return }
        detector.reset()
        stoppedAutomatically = true
        stop()
    }

    private var stoppedAutomatically = false
}

enum PermissionIssue {
    case microphone
    case screen

    var title: String {
        switch self {
        case .microphone: L("Microphone permission needed")
        case .screen: L("Permission needed to record the other side")
        }
    }

    var steps: String {
        switch self {
        case .microphone:
            L("Turn on Offrecord in System Settings › Privacy & Security › Microphone, then press record again.")
        case .screen:
            L("Turn on Offrecord in System Settings › Privacy & Security › Screen & System Audio Recording. macOS applies it after the app restarts.")
        }
    }

    func openSettings() {
        let anchor = self == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum Notifications {
    static let meetingCategory = "MEETING_DETECTED"
    static let recordAction = "RECORD_MEETING"
    static let silenceCategory = "SILENCE"
    static let stopAction = "STOP_RECORDING"

    static func configure(delegate: UNUserNotificationCenterDelegate) {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        let record = UNNotificationAction(identifier: recordAction, title: L("Record"), options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: meetingCategory, actions: [record], intentIdentifiers: []),
            UNNotificationCategory(
                identifier: silenceCategory,
                actions: [UNNotificationAction(identifier: stopAction, title: L("Stop recording"), options: [])],
                intentIdentifiers: []
            ),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func postSilence() {
        let content = UNMutableNotificationContent()
        content.title = L("Still recording")
        content.body = L("No sound for 5 minutes. If the meeting is over, you can stop the recording.")
        content.categoryIdentifier = silenceCategory
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "silence", content: content, trigger: nil))
    }

    static func postNotesReady(title: String, sessionID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = L("Notes ready")
        content.body = title
        content.userInfo = ["sessionID": sessionID.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    static func postMeetingDetected(appName: String) {
        let content = UNMutableNotificationContent()
        content.title = L("Did a call start in %@?", appName)
        content.body = L("Record it and take notes? Recording stops by itself when the call ends.")
        content.categoryIdentifier = meetingCategory
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var quickControls: QuickControls?
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifications.configure(delegate: self)
        NotificationCenter.default.addObserver(forName: .appLanguageChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Notifications.configure(delegate: self)
        }
        MainActor.assumeIsolated {
            let model = AppModel.shared
            model.startMeetingDetection()
            model.recoverUnfinished()
            model.updates.start()
            quickControls = QuickControls(model: model)
            hotKey = GlobalHotKey { MainActor.assumeIsolated { model.toggleRecording() } }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppModel.shared.openMainWindow() } }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let recorder = MainActor.assumeIsolated { AppModel.shared.recorder }
        guard MainActor.assumeIsolated({ recorder.isRecording }) else { return .terminateNow }
        Task { @MainActor in
            await recorder.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if response.notification.request.content.categoryIdentifier == Notifications.silenceCategory {
            await MainActor.run {
                if response.actionIdentifier == Notifications.stopAction { AppModel.shared.stop() } else { AppModel.shared.openMainWindow() }
            }
            return
        }
        let info = response.notification.request.content.userInfo
        if let raw = info["sessionID"] as? String, let id = UUID(uuidString: raw) {
            await MainActor.run {
                AppModel.shared.selectedSessionID = id
                AppModel.shared.openMainWindow()
            }
            return
        }
        guard response.notification.request.content.categoryIdentifier == Notifications.meetingCategory else { return }
        await MainActor.run {
            let model = AppModel.shared
            if response.actionIdentifier == Notifications.recordAction {
                model.start(.computer)
            } else {
                model.selectedSessionID = nil
            }
            model.openMainWindow()
        }
    }
}
