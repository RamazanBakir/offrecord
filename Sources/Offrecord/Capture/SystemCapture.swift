@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit

/// Captures system audio (everything the Mac plays, e.g. the other side of a call)
/// and, optionally, the main display into a .mov file via ScreenCaptureKit.
final class SystemCapture: NSObject, SCStreamOutput, SCStreamDelegate, SCRecordingOutputDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "offrecord.system-capture")
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var recordingFinished: CheckedContinuation<Void, Never>?
    private let onAudio: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// Set when the stream stops on its own (e.g. permission revoked).
    var onError: (@Sendable (Error) -> Void)?

    init(onAudio: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        self.onAudio = onAudio
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func start(captureAudio: Bool, screenURL: URL?) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.screenPermission(error)
        }
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = captureAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        if screenURL != nil {
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.showsCursor = true
            config.queueDepth = 6
            // Put the microphone into the video file too, so the .mov is self-contained.
            config.captureMicrophone = true
        } else {
            // Audio only: keep the mandatory video stream as cheap as possible.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if captureAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if config.captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }

        if let screenURL {
            let recordingConfig = SCRecordingOutputConfiguration()
            recordingConfig.outputURL = screenURL
            recordingConfig.outputFileType = .mov
            if recordingConfig.availableVideoCodecTypes.contains(.hevc) {
                recordingConfig.videoCodecType = .hevc
            }
            let output = SCRecordingOutput(configuration: recordingConfig, delegate: self)
            try stream.addRecordingOutput(output)
            recordingOutput = output
        }

        do {
            try await stream.startCapture()
        } catch {
            throw CaptureError.screenPermission(error)
        }
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        let hadRecording = recordingOutput != nil
        try? await stream.stopCapture()
        if hadRecording {
            // Wait (bounded) for the .mov to be finalised.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    await withCheckedContinuation { continuation in
                        guard let self else { return continuation.resume() }
                        self.queue.async {
                            if self.recordingOutput == nil {
                                continuation.resume()
                            } else {
                                self.recordingFinished = continuation
                            }
                        }
                    }
                }
                group.addTask { try? await Task.sleep(for: .seconds(8)) }
                await group.next()
                group.cancelAll()
            }
        }
        self.stream = nil
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let onAudio, let buffer = sampleBuffer.pcmBuffer() else { return }
        onAudio(buffer)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }

    // MARK: SCRecordingOutputDelegate

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        queue.async {
            self.recordingOutput = nil
            self.recordingFinished?.resume()
            self.recordingFinished = nil
        }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        queue.async {
            self.recordingOutput = nil
            self.recordingFinished?.resume()
            self.recordingFinished = nil
        }
    }
}

extension CMSampleBuffer {
    /// Copies an audio sample buffer into an AVAudioPCMBuffer.
    func pcmBuffer() -> AVAudioPCMBuffer? {
        guard isValid, numSamples > 0,
              let description = formatDescription,
              var asbd = description.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(numSamples)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(numSamples), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
