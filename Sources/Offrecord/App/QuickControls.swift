import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Global ⌃⌥R hotkey (Carbon, works while other apps are frontmost).
final class GlobalHotKey {
    nonisolated(unsafe) private static var action: (() -> Void)?
    private var reference: EventHotKeyRef?

    init(action: @escaping () -> Void) {
        GlobalHotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { GlobalHotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4D_4E_54_53), id: 1) // "MNTS"
        RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &reference)
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
    }
}

/// Menu bar item: left click starts/stops, right click shows the menu.
/// Also shows and hides the floating recording panel.
@MainActor
final class QuickControls: NSObject {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: RecordingPanel?
    private var timer: Timer?

    init(model: AppModel) {
        self.model = model
        super.init()
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            model.toggleRecording()
        }
    }

    private func refresh() {
        guard let button = item.button else { return }
        let recorder = model.recorder
        switch recorder.phase {
        case .recording:
            button.image = symbol(recorder.isPaused ? "pause.circle.fill" : "record.circle.fill", color: recorder.isPaused ? .systemOrange : .systemRed)
            button.title = " " + recorder.elapsed.clockString
        case .preparing, .finishing:
            button.image = symbol("hourglass", color: nil)
            button.title = ""
        case .idle:
            button.image = symbol("waveform.circle", color: nil)
            button.title = ""
        }
        button.toolTip = recorder.isRecording ? L("Click to stop (⌃⌥R)") : L("Click to start recording (⌃⌥R)")

        if recorder.isActive {
            if panel == nil { panel = RecordingPanel(model: model) }
            panel?.orderFrontRegardless()
        } else if let panel {
            panel.orderOut(nil)
            self.panel = nil
        }
    }

    private func symbol(_ name: String, color: NSColor?) -> NSImage? {
        var config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if let color { config = config.applying(.init(paletteColors: [color])) }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Offrecord")?.withSymbolConfiguration(config)
        image?.isTemplate = color == nil
        return image
    }

    private func showMenu() {
        let menu = NSMenu()
        let recorder = model.recorder
        if recorder.isRecording {
            menu.addItem(action(L("Stop recording  ⌃⌥R")) { [model] in model.stop() })
            menu.addItem(action(recorder.isPaused ? L("Resume") : L("Pause")) { [model] in model.recorder.togglePause() })
            menu.addItem(action(L("Mark important moment")) { [model] in model.recorder.addBookmark() })
        } else if !recorder.isActive {
            for mode in RecordMode.allCases {
                menu.addItem(action(L("Record: %@", mode.title)) { [model] in model.start(mode) })
            }
        }
        menu.addItem(.separator())
        menu.addItem(action(L("Open Offrecord")) { [model] in model.openMainWindow() })
        menu.addItem(action(L("Quit")) { NSApp.terminate(nil) })
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    private func action(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let menuItem = ClosureMenuItem(title: title, handler: handler)
        return menuItem
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}

// MARK: - Floating panel

/// Small always-on-top panel shown while recording, above every app and Space.
final class RecordingPanel: NSPanel {
    @MainActor
    init(model: AppModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 52),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false

        let host = NSHostingView(rootView: RecordingPill().environment(model))
        host.frame = contentRect(forFrameRect: frame)
        contentView = host

        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.maxY - frame.height - 12))
        }
    }

    // Allows typing a note without activating the app.
    override var canBecomeKey: Bool { true }
}

struct RecordingPill: View {
    @Environment(AppModel.self) private var model
    @State private var note = ""

    private var recorder: RecordingController { model.recorder }

    var body: some View {
        HStack(spacing: 12) {
            switch recorder.phase {
            case .recording:
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    HStack(spacing: 7) {
                        Circle().fill(recorder.isPaused ? .orange : .red).frame(width: 9, height: 9)
                        Text(recorder.isPaused ? L("Paused") : recorder.elapsed.clockString)
                            .font(.body.monospacedDigit().weight(.semibold))
                    }
                }
                if recorder.remoteSideSilent {
                    Image(systemName: "speaker.slash.fill")
                        .foregroundStyle(.orange)
                        .help(L("No sound from the other side"))
                } else {
                    LevelBars(levels: recorder.levels, hasRemote: recorder.meta?.options.systemAudio == true)
                }
                TextField(L("Take a note, Enter…"), text: $note)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        recorder.addNote(note)
                        note = ""
                    }
                Button {
                    recorder.togglePause()
                } label: {
                    Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.borderless)
                .help(L("Pause / resume"))
                Button {
                    recorder.addBookmark()
                } label: {
                    Image(systemName: "star")
                }
                .buttonStyle(.borderless)
                .help(L("Important moment"))
                Button {
                    model.stop()
                } label: {
                    Label(L("Stop"), systemImage: "stop.fill")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .help(L("Stop recording (⌃⌥R)"))
            case .preparing(let status), .finishing(let status):
                ProgressView().controlSize(.small)
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 560, height: 52)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
    }
}
