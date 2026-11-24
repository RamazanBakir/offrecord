@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit

/// One uninterrupted stretch of screen video and where it starts on the session timeline.
struct ScreenPart: Codable, Equatable, Sendable {
    var file: String
    /// Seconds from the session start (the same zero point as the audio files).
    var offset: TimeInterval

    static func load(from folder: URL) -> [ScreenPart] {
        guard let data = try? Data(contentsOf: folder.appending(path: SessionFiles.screenParts)) else { return [] }
        return (try? JSONDecoder().decode([ScreenPart].self, from: data)) ?? []
    }

    static func save(_ parts: [ScreenPart], in folder: URL) {
        guard let data = try? JSONEncoder().encode(parts) else { return }
        try? data.write(to: folder.appending(path: SessionFiles.screenParts), options: .atomic)
    }
}

/// Records a display or a single window, video only. Every start/resume opens a new
/// part file and every pause/stop closes it, so nothing is captured while paused.
/// Switching to another display or window also starts a new part; all parts share
/// the first part's frame size (other content is fitted inside it) so they join
/// into one video without re-encoding.
/// The parts are listed in screen-parts.json as they start (crash safety) and turned
/// into screen.mov with the session audio by `ScreenRecordingAssembler`.
///
/// Call `start`, `pause`, `resume`, `switchTarget` and `stop` one at a time (not concurrently).
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    private var filter: SCContentFilter
    /// Pixel size of every part, fixed by the first one.
    private var frameSize: (width: Int, height: Int)?
    private let folder: URL
    private let sessionStart: Date
    private let queue = DispatchQueue(label: "offrecord.screen")
    private var stream: SCStream?
    private var partCount = 0

    // Shared with the delegate callbacks; guarded by `lock`.
    private let lock = NSLock()
    private var parts: [ScreenPart] = []
    private var startingFile: String?
    private var activeOutput: SCRecordingOutput?
    private var fileClosed: CheckedContinuation<Void, Never>?
    private var targetLost = false

    /// Called when capture ends on its own: window closed, display disconnected,
    /// sharing stopped from the menu bar. Later resumes are ignored until
    /// `switchTarget` picks something else.
    var onError: (@Sendable (Error) -> Void)?

    init(filter: SCContentFilter, folder: URL, sessionStart: Date) {
        self.filter = filter
        self.folder = folder
        self.sessionStart = sessionStart
    }

    func start() async throws {
        guard stream == nil, !lock.withLock({ targetLost }) else { return }
        partCount += 1
        let file = SessionFiles.screenPart(partCount)

        let stream = SCStream(filter: filter, configuration: makeStreamConfiguration(), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = folder.appending(path: file)
        recording.outputFileType = .mov
        if recording.availableVideoCodecTypes.contains(.hevc) {
            recording.videoCodecType = .hevc
        }
        let output = SCRecordingOutput(configuration: recording, delegate: self)
        try stream.addRecordingOutput(output)
        lock.withLock {
            startingFile = file
            activeOutput = output
        }
        do {
            try await stream.startCapture()
        } catch {
            lock.withLock {
                startingFile = nil
                activeOutput = nil
            }
            throw error
        }
        self.stream = stream
    }

    func pause() async {
        await closePart()
    }

    func resume() async throws {
        try await start()
    }

    func stop() async {
        await closePart()
    }

    /// Records `newFilter` from now on. While paused it takes effect on resume.
    func switchTarget(to newFilter: SCContentFilter, paused: Bool) async throws {
        await closePart()
        filter = newFilter
        lock.withLock { targetLost = false }
        if !paused { try await start() }
    }

    private func makeStreamConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        let content = CGSize(width: filter.contentRect.width * scale, height: filter.contentRect.height * scale)
        // Even pixel sizes keep the HEVC/H.264 encoder happy.
        let size = frameSize ?? (max(2, Int(content.width) / 2 * 2), max(2, Int(content.height) / 2 * 2))
        frameSize = size
        config.width = size.width
        config.height = size.height
        config.destinationRect = Self.centeredFit(content, in: CGSize(width: size.width, height: size.height))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.queueDepth = 6
        // A resized window, or content of another size after a switch, stays whole inside the frame.
        config.scalesToFit = true
        config.preservesAspectRatio = true
        return config
    }

    /// Where content of another shape goes inside the frame: as large as fits, centered.
    static func centeredFit(_ content: CGSize, in frame: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return CGRect(origin: .zero, size: frame) }
        let scale = min(frame.width / content.width, frame.height / content.height)
        let fitted = CGSize(width: (content.width * scale).rounded(), height: (content.height * scale).rounded())
        return CGRect(x: ((frame.width - fitted.width) / 2).rounded(), y: ((frame.height - fitted.height) / 2).rounded(),
                      width: fitted.width, height: fitted.height)
    }

    /// Stops the stream and waits (at most 8 s) until the part file is finalized.
    private func closePart() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    let alreadyClosed = self.lock.withLock {
                        guard self.activeOutput != nil else { return true }
                        self.fileClosed = continuation
                        return false
                    }
                    if alreadyClosed { continuation.resume() }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                self.resumeFileClosed()
            }
            await group.next()
            group.cancelAll()
        }
        lock.withLock { activeOutput = nil }
    }

    private func resumeFileClosed() {
        let continuation = lock.withLock {
            defer { fileClosed = nil }
            return fileClosed
        }
        continuation?.resume()
    }

    private func partEnded() {
        lock.withLock {
            activeOutput = nil
            startingFile = nil
        }
        resumeFileClosed()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Frames go straight into the recording output; nothing to do here.
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.withLock { targetLost = true }
        onError?(error)
    }

    // MARK: SCRecordingOutputDelegate

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        let offset = Date().timeIntervalSince(sessionStart)
        lock.withLock {
            guard let file = startingFile else { return }
            startingFile = nil
            parts.append(ScreenPart(file: file, offset: max(0, offset)))
            ScreenPart.save(parts, in: folder)
        }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        partEnded()
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        partEnded()
    }
}
