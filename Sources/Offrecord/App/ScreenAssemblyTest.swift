@preconcurrency import AVFoundation
import Foundation

/// `--screen-assembly-test <dir>`: builds synthetic screen parts and audio, runs
/// `ScreenRecordingAssembler` on them and prints PASS/FAIL per case.
enum ScreenAssemblyTest {
    static func run(directory: URL) async {
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print(condition ? "  PASS" : "  FAIL", label)
            if !condition { failures += 1 }
        }

        print("== Two parts with a pause gap + audio")
        let folder = freshFolder(directory, "paused")
        do {
            try await writeClip(folder.appending(path: SessionFiles.screenPart(1)), seconds: 1.0)
            try await writeClip(folder.appending(path: SessionFiles.screenPart(2)), seconds: 1.5)
            try await writeTone(folder.appending(path: SessionFiles.audio), seconds: 6)
            ScreenPart.save([ScreenPart(file: SessionFiles.screenPart(1), offset: 0.4),
                             ScreenPart(file: SessionFiles.screenPart(2), offset: 3.0)], in: folder)
            let output = folder.appending(path: SessionFiles.screen)
            try await ScreenRecordingAssembler.finalize(folder: folder, audio: folder.appending(path: SessionFiles.audio), into: output)
            let asset = AVURLAsset(url: output)
            let video = try await asset.loadTracks(withMediaType: .video)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            check(video.count == 1 && audio.count == 1, "one video and one audio track")
            let duration = try await asset.load(.duration).seconds
            check(abs(duration - 6) < 0.15, "duration follows the session timeline (\(String(format: "%.2f", duration)) s)")
            let segments = try await video[0].load(.segments).filter { !$0.isEmpty }
            let starts = segments.map { $0.timeMapping.target.start.seconds }
            check(starts.count == 2 && abs(starts[0] - 0.4) < 0.05 && abs(starts[1] - 3.0) < 0.05,
                  "parts placed at their offsets (\(starts.map { String(format: "%.2f", $0) }))")
            check(remaining(folder) == [SessionFiles.audio, SessionFiles.screen], "parts and list removed")
        } catch {
            check(false, "assembly threw \(error)")
        }

        print("== Crash leftovers: one unreadable part, no audio")
        let crashed = freshFolder(directory, "crashed")
        do {
            try await writeClip(crashed.appending(path: SessionFiles.screenPart(1)), seconds: 1.0)
            try Data(repeating: 7, count: 4096).write(to: crashed.appending(path: SessionFiles.screenPart(2)))
            ScreenPart.save([ScreenPart(file: SessionFiles.screenPart(1), offset: 0),
                             ScreenPart(file: SessionFiles.screenPart(2), offset: 2)], in: crashed)
            let output = crashed.appending(path: SessionFiles.screen)
            try await ScreenRecordingAssembler.finalize(folder: crashed, audio: crashed.appending(path: SessionFiles.audio), into: output)
            let asset = AVURLAsset(url: output)
            check(try await asset.loadTracks(withMediaType: .video).count == 1, "readable part kept")
            check(try await asset.loadTracks(withMediaType: .audio).isEmpty, "no audio track when audio is missing")
        } catch {
            check(false, "assembly threw \(error)")
        }

        print("== Only an unreadable part")
        let broken = freshFolder(directory, "broken")
        try? Data(repeating: 7, count: 4096).write(to: broken.appending(path: SessionFiles.screenPart(1)))
        ScreenPart.save([ScreenPart(file: SessionFiles.screenPart(1), offset: 0)], in: broken)
        do {
            try await ScreenRecordingAssembler.finalize(folder: broken, audio: broken.appending(path: SessionFiles.audio), into: broken.appending(path: SessionFiles.screen))
            check(false, "should have thrown")
        } catch {
            check(remaining(broken) == [SessionFiles.screen], "error reported, the single part kept as screen.mov")
        }

        print("== No parts (audio-only session)")
        let audioOnly = freshFolder(directory, "audio-only")
        do {
            try await ScreenRecordingAssembler.finalize(folder: audioOnly, audio: audioOnly.appending(path: SessionFiles.audio), into: audioOnly.appending(path: SessionFiles.screen))
            check(remaining(audioOnly).isEmpty, "nothing created")
        } catch {
            check(false, "threw \(error)")
        }

        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
    }

    private static func freshFolder(_ directory: URL, _ name: String) -> URL {
        let folder = directory.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func remaining(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// Writes a small H.264 .mov of solid frames at 30 fps.
    private static func writeClip(_ url: URL, seconds: Double) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 200,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<Int(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 8 % 255), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// Writes a 440 Hz tone as AAC .m4a.
    private static func writeTone(_ url: URL, seconds: Double) async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = 0.2 * sin(Float(i) * 2 * .pi * 440 / 48_000) }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        ])
        try file.write(from: buffer)
    }
}
