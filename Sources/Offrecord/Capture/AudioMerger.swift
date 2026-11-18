import AVFoundation

/// Mixes the microphone and system audio files (same timeline) into one audio.m4a.
enum AudioMerger {
    static func merge(_ inputs: [URL], into output: URL) async throws {
        let existing = inputs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        try? FileManager.default.removeItem(at: output)

        let composition = AVMutableComposition()
        for url in existing {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try await export.export(to: output, as: .m4a)
        for url in existing { try? FileManager.default.removeItem(at: url) }
    }

    /// Builds audio.m4a from the crash-safe intermediates: speech-leveled mix,
    /// or a plain mix if leveling fails. Removes the intermediates on success.
    /// Returns true when leveling was applied.
    @discardableResult
    static func finalize(folder: URL, into output: URL) async throws -> Bool {
        let mic = folder.appending(path: SessionFiles.micAudio)
        let system = folder.appending(path: SessionFiles.systemAudio)
        let inputs = [mic, system].filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !inputs.isEmpty else { return false }
        do {
            try await SpeechEnhancer.render(
                [.init(url: mic, highPass: true), .init(url: system, highPass: false)], to: output
            )
            for url in inputs { try? FileManager.default.removeItem(at: url) }
            return true
        } catch {
            try await merge(inputs, into: output)
            return false
        }
    }

    /// Extracts the audio track of any media file (e.g. a .mov) into an .m4a for transcription.
    static func extractAudio(from input: URL, to output: URL) async throws {
        try? FileManager.default.removeItem(at: output)
        let asset = AVURLAsset(url: input)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw TranscriptionError.noAudioTrack
        }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try await export.export(to: output, as: .m4a)
    }
}
