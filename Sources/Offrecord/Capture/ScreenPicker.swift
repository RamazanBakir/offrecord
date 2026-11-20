import AppKit
@preconcurrency import ScreenCaptureKit

/// What a screen recording shows: one whole display or one window.
/// Stored so the next recording can reuse it without asking again.
enum ScreenTarget: Codable, Hashable, Sendable {
    case display(id: CGDirectDisplayID, name: String)
    case window(id: CGWindowID, appName: String, title: String)

    var label: String {
        switch self {
        case .display(_, let name):
            return L("Entire screen: %@", name)
        case .window(_, let appName, let title):
            let shortTitle = title.count > 40 ? title.prefix(39) + "…" : Substring(title)
            return L("Window: %@", shortTitle.isEmpty || shortTitle == appName ? appName : "\(appName) – \(shortTitle)")
        }
    }

    /// Reads the choice back from a filter returned by the system picker.
    init?(_ filter: SCContentFilter) {
        switch filter.style {
        case .display:
            guard let display = filter.includedDisplays.first else { return nil }
            self = .display(id: display.displayID, name: Self.displayName(display.displayID))
        case .window:
            guard let window = filter.includedWindows.first else { return nil }
            self = .window(id: window.windowID, appName: window.owningApplication?.applicationName ?? "", title: window.title ?? "")
        default:
            return nil
        }
    }

    /// Builds the capture filter. Offrecord's own windows are left out of a display
    /// recording. Throws when the display was disconnected or the window closed.
    func makeFilter() async throws -> SCContentFilter {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch {
            throw CaptureError.screenPermission(error)
        }
        switch self {
        case .display(let id, _):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.screenTargetGone }
            let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            return SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
        case .window(let id, _, _):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.screenTargetGone }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    private static func displayName(_ id: CGDirectDisplayID) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screen = NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id }
        return screen?.localizedName ?? L("Display")
    }
}

/// Shows the system "choose what to share" picker, the same one call apps use,
/// limited to a whole display or a single window.
@MainActor
final class ScreenPicker: NSObject, SCContentSharingPickerObserver {
    private var pending: CheckedContinuation<SCContentFilter?, Never>?

    /// The chosen content, or nil when the user cancels.
    func choose() async -> SCContentFilter? {
        guard pending == nil else { return nil }
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow]
        configuration.allowsChangingSelectedContent = false
        if let bundleID = Bundle.main.bundleIdentifier {
            configuration.excludedBundleIDs = [bundleID]
        }
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        NSApp.activate()
        return await withCheckedContinuation { continuation in
            pending = continuation
            picker.present()
        }
    }

    private func finish(with filter: SCContentFilter?) {
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
        pending?.resume(returning: filter)
        pending = nil
    }

    // MARK: SCContentSharingPickerObserver

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in self.finish(with: filter) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.finish(with: nil) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in self.finish(with: nil) }
    }
}
