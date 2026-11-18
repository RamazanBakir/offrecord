import AppKit
import CoreAudio
import Foundation

/// Watches which apps are using a microphone (Core Audio process objects, macOS 14.2+).
/// Detects a call starting in another app (Zoom, Meet in a browser, WhatsApp, FaceTime…)
/// and the call ending, so recordings can start and stop on their own.
@MainActor
final class MeetingDetector {
    struct CallApp: Equatable {
        var bundleID: String
        var name: String
    }

    /// Another app started using the microphone.
    var onCallStarted: ((CallApp) -> Void)?
    /// No other app has used the microphone for `endGrace` seconds after a call.
    var onCallEnded: (() -> Void)?

    private(set) var activeApps: [CallApp] = []
    private var timer: Timer?
    private var silentSince: Date?
    private var sawCall = false
    private let endGrace: TimeInterval = 8
    /// Injectable for tests.
    var appsProvider: () -> [CallApp] = MeetingDetector.appsUsingMicrophone
    var clock: () -> Date = Date.init

    /// System helpers that use the microphone but are not calls.
    private static let ignored: Set<String> = [
        "com.apple.replayd", "com.apple.corespeechd", "com.apple.assistantd", "com.apple.Siri",
        "com.apple.SpeechRecognitionCore.speechrecognitiond", "com.apple.controlcenter", "com.apple.dictationim",
    ]

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    /// Call when a recording starts: arms call-end detection for this recording.
    func recordingStarted() {
        sawCall = !activeApps.isEmpty
        silentSince = nil
    }

    /// Call after the recording was stopped because the call ended.
    func reset() {
        sawCall = false
        silentSince = nil
    }

    func poll() {
        let now = appsProvider()
        let previous = activeApps
        activeApps = now

        if let started = now.first(where: { app in !previous.contains(app) }), previous.isEmpty {
            onCallStarted?(started)
        }
        if !now.isEmpty {
            sawCall = true
            silentSince = nil
        } else if sawCall {
            // Keeps reporting until reset(), so the owner can wait for the remote side to go quiet too.
            let since = silentSince ?? clock()
            silentSince = since
            if clock().timeIntervalSince(since) >= endGrace {
                onCallEnded?()
            }
        }
    }

    static func appsUsingMicrophone() -> [CallApp] {
        let ownPID = getpid()
        return processObjects().compactMap { object -> CallApp? in
            guard uint32(object, kAudioProcessPropertyIsRunningInput) != 0 else { return nil }
            let pid = pid_t(bitPattern: uint32(object, kAudioProcessPropertyPID))
            guard pid != ownPID else { return nil }
            let bundleID = string(object, kAudioProcessPropertyBundleID) ?? ""
            guard !ignored.contains(bundleID), bundleID != Bundle.main.bundleIdentifier else { return nil }
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? bundleID.split(separator: ".").last.map(String.init) ?? L("An app")
            return CallApp(bundleID: bundleID, name: Self.friendlyName(bundleID: bundleID, fallback: name))
        }
    }

    /// Browser helper processes report as e.g. "Google Chrome Helper"; show the browser.
    private static func friendlyName(bundleID: String, fallback: String) -> String {
        if bundleID.hasPrefix("com.google.Chrome") { return "Chrome" }
        if bundleID.hasPrefix("com.apple.WebKit") || bundleID.hasPrefix("com.apple.Safari") { return "Safari" }
        if bundleID.hasPrefix("company.thebrowser") { return "Arc" }
        if bundleID.hasPrefix("org.mozilla") { return "Firefox" }
        if bundleID.hasPrefix("com.microsoft.edgemac") { return "Edge" }
        return fallback.replacingOccurrences(of: " Helper", with: "")
    }

    // MARK: Core Audio helpers

    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
