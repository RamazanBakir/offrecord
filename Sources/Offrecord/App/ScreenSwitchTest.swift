@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit

/// `--screen-switch-test <dir>`: records the main display, switches to a window,
/// pauses, switches back while paused, resumes and stops, then assembles the parts.
/// Needs Screen Recording permission, so launch the installed app with `open`.
enum ScreenSwitchTest {
    static func run(directory: URL) async {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print(condition ? "  PASS" : "  FAIL", label)
            if !condition { failures += 1 }
        }

        let folder = directory.appending(path: "switch", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let display = content.displays.first,
                  let window = content.windows.first(where: { $0.windowLayer == 0 && $0.frame.width > 300 && $0.frame.height > 200
                      && abs($0.frame.width / $0.frame.height - display.frame.width / display.frame.height) > 0.1 })
            else {
                print("  FAIL no display or suitably shaped window to switch to")
                return
            }
            print("== Display \(Int(display.frame.width))x\(Int(display.frame.height)) -> window \(window.owningApplication?.applicationName ?? "?") \(Int(window.frame.width))x\(Int(window.frame.height))")
            let displayFilter = SCContentFilter(display: display, excludingWindows: [])
            let windowFilter = SCContentFilter(desktopIndependentWindow: window)

            let start = Date()
            let capture = ScreenCapture(filter: displayFilter, folder: folder, sessionStart: start)
            try await capture.start()
            try await Task.sleep(for: .seconds(2))
            try await capture.switchTarget(to: windowFilter, paused: false)
            try await Task.sleep(for: .seconds(2))
            await capture.pause()
            try await Task.sleep(for: .seconds(1))
            try await capture.switchTarget(to: displayFilter, paused: true)
            try await Task.sleep(for: .milliseconds(500))
            try await capture.resume()
            try await Task.sleep(for: .seconds(1.5))
            await capture.stop()
            let total = Date().timeIntervalSince(start)

            let parts = ScreenPart.load(from: folder)
            check(parts.count == 3, "three parts: display, window, display (\(parts.count))")
            var sizes: [CGSize] = []
            for part in parts {
                let track = try await AVURLAsset(url: folder.appending(path: part.file)).loadTracks(withMediaType: .video).first
                if let track { sizes.append(try await track.load(.naturalSize)) }
            }
            check(sizes.count == parts.count && Set(sizes.map { "\($0)" }).count == 1, "every part has the same frame size (\(sizes))")
            check(parts.count == 3 && parts[2].offset - parts[1].offset > 3, "pause gap kept before the last part (\(parts.map { String(format: "%.2f", $0.offset) }))")

            let audio = folder.appending(path: SessionFiles.audio)
            try await ScreenAssemblyTest.writeTone(audio, seconds: total)
            let output = folder.appending(path: SessionFiles.screen)
            try await ScreenRecordingAssembler.finalize(folder: folder, audio: audio, into: output)
            let asset = AVURLAsset(url: output)
            let video = try await asset.loadTracks(withMediaType: .video)
            check(video.count == 1, "one video track")
            let segments = try await video.first?.load(.segments).filter { !$0.isEmpty }.count ?? 0
            check(segments == 3, "three video segments in screen.mov (\(segments))")
            let duration = try await asset.load(.duration).seconds
            check(abs(duration - total) < 0.5, "duration follows the session (\(String(format: "%.2f / %.2f", duration, total)) s)")
        } catch {
            check(false, "threw \(error)")
        }
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
    }
}
