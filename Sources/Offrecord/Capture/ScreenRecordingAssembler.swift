import AVFoundation

/// Builds screen.mov from the recorded screen parts. Each part is placed at its
/// offset on the session timeline, so paused stretches stay as gaps exactly like
/// in audio.m4a and the transcript times match the video. The soundtrack is the
/// session's final audio (echo-cancelled microphone + system audio), so the
/// video sounds the same as the audio recording. Video frames are copied, not re-encoded.
enum ScreenRecordingAssembler {
    enum AssemblyError: LocalizedError {
        case noReadableVideo
        case exportUnavailable

        var errorDescription: String? {
            switch self {
            case .noReadableVideo: L("No readable screen video was recorded.")
            case .exportUnavailable: L("The video could not be written.")
            }
        }
    }

    /// Assembles the parts listed in `folder` (no-op when there are none) and removes
    /// them. On failure a single part is kept as screen.mov without the final audio,
    /// so the video still opens; then the error is rethrown.
    static func finalize(folder: URL, audio: URL, into output: URL) async throws {
        let parts = ScreenPart.load(from: folder)
        guard !parts.isEmpty else { return }
        do {
            try await assemble(parts, in: folder, audio: audio, into: output)
            removeParts(in: folder)
        } catch {
            if parts.count == 1, !FileManager.default.fileExists(atPath: output.path),
               (try? FileManager.default.moveItem(at: folder.appending(path: parts[0].file), to: output)) != nil {
                removeParts(in: folder)
            }
            throw error
        }
    }

    private static func assemble(_ parts: [ScreenPart], in folder: URL, audio: URL, into output: URL) async throws {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AssemblyError.exportUnavailable
        }
        // A track only weakly references its asset: keep the assets alive until export ends.
        var sources: [AVURLAsset] = []
        var transform: CGAffineTransform?
        // End of the video placed so far (an empty track's timeRange is invalid, so track it here).
        var end = CMTime.zero
        for part in parts.sorted(by: { $0.offset < $1.offset }) {
            let asset = AVURLAsset(url: folder.appending(path: part.file))
            sources.append(asset)
            // A part cut off by a crash may be unreadable; keep the others.
            guard let source = try? await asset.loadTracks(withMediaType: .video).first,
                  let range = try? await source.load(.timeRange), range.duration > .zero
            else { continue }
            let start = CMTimeMaximum(CMTime(seconds: part.offset, preferredTimescale: 600), end)
            if start > end {
                video.insertEmptyTimeRange(CMTimeRange(start: end, end: start))
            }
            try video.insertTimeRange(range, of: source, at: start)
            end = start + range.duration
            if transform == nil { transform = try? await source.load(.preferredTransform) }
        }
        guard end > .zero else { throw AssemblyError.noReadableVideo }
        video.preferredTransform = transform ?? .identity

        let audioAsset = AVURLAsset(url: audio)
        sources.append(audioAsset)
        if FileManager.default.fileExists(atPath: audio.path),
           let source = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try track.insertTimeRange(try await source.load(.timeRange), of: source, at: .zero)
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw AssemblyError.exportUnavailable
        }
        let temporary = folder.appending(path: "screen-assembling.mov")
        try? FileManager.default.removeItem(at: temporary)
        do {
            try await export.export(to: temporary, as: .mov)
            withExtendedLifetime(sources) {}
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: temporary, to: output)
    }

    /// Removes every part file, including one too short to have been listed.
    private static func removeParts(in folder: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for file in files where file.hasPrefix(SessionFiles.screenPartPrefix) {
            try? FileManager.default.removeItem(at: folder.appending(path: file))
        }
        try? FileManager.default.removeItem(at: folder.appending(path: SessionFiles.screenParts))
    }
}
