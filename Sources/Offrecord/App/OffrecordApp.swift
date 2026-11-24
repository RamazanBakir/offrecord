import SwiftUI
import UniformTypeIdentifiers

struct OffrecordApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Offrecord", id: "main") {
            ContentView()
                .environment(model)
                .environment(\.locale, Localizer.shared.language.locale)
                .frame(minWidth: 760, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("Start recording")) { model.start() }
                    .disabled(model.recorder.isActive)
                Button(L("Stop recording")) { model.stop() }
                    .keyboardShortcut(".")
                    .disabled(!model.recorder.isRecording)
                Button(model.recorder.isPaused ? L("Resume") : L("Pause")) { model.recorder.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!model.recorder.isRecording)
                Button(L("Change screen…")) { model.changeScreen() }
                    .disabled(!model.recorder.canChangeScreen || model.isChoosingScreen)
                Button(L("Mark important moment")) { model.recorder.addBookmark() }
                    .keyboardShortcut("b")
                    .disabled(!model.recorder.isRecording)
                Divider()
                Button(L("Open audio/video file…")) { openFile() }
                    .keyboardShortcut("o")
                Button(L("Delete selected recording…")) { model.requestDeleteSelected() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selectedSessionID == nil)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(\.locale, Localizer.shared.language.locale)
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
        panel.prompt = L("Transcribe")
        if panel.runModal() == .OK, let url = panel.url {
            model.importFile(url)
        }
    }
}
