import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SettingsKeys.detectMeetings) private var detectMeetings = true
    @AppStorage(SettingsKeys.localeIdentifier) private var localeID = SettingsKeys.defaultSpeechLocale
    @AppStorage(SessionStore.storagePathKey) private var storagePath = ""
    @State private var locales: [Locale] = []
    @AppStorage(SettingsKeys.useCalendar) private var useCalendar = true
    @AppStorage(SettingsKeys.autoStopOnCallEnd) private var autoStop = true
    @AppStorage(SettingsKeys.voiceProcessing) private var voiceProcessing = true
    @Bindable private var localizer = Localizer.shared
    @State private var launchLanguage = Localizer.shared.language
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            model.recorder.errorMessage = L("Couldn't change the login item: %@", error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var body: some View {
        Form {
            Section {
                Picker(L("Language"), selection: $localizer.language) {
                    ForEach(AppLanguage.allCases) { Text($0.nativeName).tag($0) }
                }
                if localizer.language != launchLanguage {
                    HStack {
                        Text(L("Some macOS menus switch after a restart."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L("Restart now")) { model.relaunch() }
                    }
                }
            }
            Section(L("Recording")) {
                Picker(L("Transcription language"), selection: $localeID) {
                    if locales.isEmpty { Text(TranscriberModule.displayName(Locale(identifier: localeID))).tag(localeID) }
                    ForEach(locales, id: \.identifier) { Text(TranscriberModule.displayName($0)).tag($0.identifier) }
                }
                Toggle(L("Suggest recording when another app uses the microphone"), isOn: $detectMeetings)
                Toggle(L("Stop recording automatically when the call ends"), isOn: $autoStop)
                Toggle(L("Improve my voice in calls (echo, noise, automatic level)"), isOn: $voiceProcessing)
                Toggle(L("Take title and attendees from Calendar"), isOn: $useCalendar)
                Toggle(L("Open Offrecord at login"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
            }
            Section(L("Storage")) {
                LabeledContent(L("Folder")) {
                    Text(model.store.rootURL.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button(L("Change…")) { chooseFolder() }
                    Button(L("Open in Finder")) { NSWorkspace.shared.open(model.store.rootURL) }
                    if !storagePath.isEmpty {
                        Button(L("Reset to default")) {
                            storagePath = ""
                            model.store.reload()
                        }
                    }
                }
            }
            Section(L("Notes")) {
                LabeledContent(L("Engine"), value: NoteGenerator.engineDescription(for: Locale(identifier: localeID)))
                Text(L("If Apple Intelligence is on and supports the language, it writes the notes on-device. Otherwise local rule-based extraction is used. No data leaves this Mac."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(L("Permissions")) {
                Button(L("Open Screen & System Audio Recording settings")) { SystemAudioCapture.openPrivacySettings() }
            }
            Section(L("About")) {
                LabeledContent(L("Version"), value: "\(AppInfo.version) (\(AppInfo.build))")
                Toggle(L("Check for updates automatically"), isOn: Binding(
                    get: { model.updates.isEnabled },
                    set: { model.updates.isEnabled = $0 }
                ))
                HStack {
                    Button(L("Check now")) { Task { await model.updates.check(manual: true) } }
                        .disabled(model.updates.status == .checking)
                    updateStatus
                }
                HStack {
                    Link(L("GitHub"), destination: AppInfo.repositoryURL)
                    Link(L("Release notes"), destination: AppInfo.releasesURL)
                    Link(L("Report a problem"), destination: AppInfo.issuesURL)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .task { locales = await TranscriberModule.availableLocales() }
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch model.updates.status {
        case .idle: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .upToDate: Text(L("You're up to date.")).foregroundStyle(.secondary)
        case .available(let version): Text(L("Version %@ is available.", version)).foregroundStyle(.tint)
        case .failed: Text(L("Couldn't reach GitHub. Try again later.")).foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Choose")
        if panel.runModal() == .OK, let url = panel.url {
            storagePath = url.path(percentEncoded: false)
            model.store.reload()
        }
    }
}
