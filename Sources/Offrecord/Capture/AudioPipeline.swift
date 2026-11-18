@preconcurrency import AVFoundation

/// Converts PCM buffers between formats with a persistent AVAudioConverter.
final class FormatConverter {
    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == outputFormat { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converter?.downmix = true
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error || output.frameLength == 0 { return nil }
        return output
    }
}

/// Writes buffers as 24 kHz 16-bit PCM CAF. Unlike .m4a, a CAF file stays
/// readable when the app is killed mid-recording, so nothing is lost on a crash.
final class AudioFileWriter {
    static let sampleRate: Double = 24_000

    let url: URL
    private var file: AVAudioFile?
    private let converter = FormatConverter(outputFormat: AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioFileWriter.sampleRate, channels: 1, interleaved: false
    )!)

    init(url: URL) {
        self.url = url
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer) else { return }
        if file == nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        try? file?.write(from: converted)
    }

    func close() {
        file?.close()
        file = nil
    }
}

/// One audio source (microphone or system audio). Normalises every buffer to
/// 48 kHz mono, pads gaps with silence so the file timeline matches wall-clock
/// session time, then fans out to the file writer and the live transcriber.
final class AudioPipeline: @unchecked Sendable {
    static let sampleRate: Double = 48_000

    let speaker: Speaker
    let fileURL: URL

    private let lock = NSLock()
    private let canonicalFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioPipeline.sampleRate, channels: 1, interleaved: false
    )!
    private let converter: FormatConverter
    private let writer: AudioFileWriter
    private var transcriber: LiveTranscriber?
    private var sessionStart: Date?
    private var framesWritten: AVAudioFramePosition = 0
    private var finished = false
    private var paused = false

    /// Called with an RMS level in 0...1 (on the audio thread).
    var onLevel: (@Sendable (Float) -> Void)?

    var hasAudio: Bool {
        lock.withLock { framesWritten > 0 }
    }

    init(speaker: Speaker, fileURL: URL) {
        self.speaker = speaker
        self.fileURL = fileURL
        self.converter = FormatConverter(outputFormat: canonicalFormat)
        self.writer = AudioFileWriter(url: fileURL)
    }

    func attach(transcriber: LiveTranscriber?) {
        lock.withLock { self.transcriber = transcriber }
    }

    /// While paused incoming audio is dropped; the gap becomes silence on resume.
    func setPaused(_ value: Bool) {
        lock.withLock { paused = value }
    }

    func begin(at date: Date) {
        lock.withLock { sessionStart = date }
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, !paused, let sessionStart, let mono = converter.convert(buffer) else { return }

        // Where this buffer should start on the session timeline (it arrives at its end).
        let arrival = Date().timeIntervalSince(sessionStart) * Self.sampleRate
        let expectedStart = AVAudioFramePosition(arrival) - AVAudioFramePosition(mono.frameLength)
        let gap = expectedStart - framesWritten
        if gap > AVAudioFramePosition(Self.sampleRate * 0.25) {
            writeSilence(frames: min(gap, AVAudioFramePosition(Self.sampleRate * 3600)))
        }
        emit(mono)
        reportLevel(mono)
    }

    func finish() {
        lock.withLock {
            finished = true
            writer.close()
        }
    }

    private func writeSilence(frames: AVAudioFramePosition) {
        var remaining = frames
        let chunk = AVAudioFramePosition(Self.sampleRate)
        while remaining > 0 {
            let count = AVAudioFrameCount(min(remaining, chunk))
            guard let silent = AVAudioPCMBuffer(pcmFormat: canonicalFormat, frameCapacity: count) else { return }
            silent.frameLength = count // AVAudioPCMBuffer memory is zero-initialised
            emit(silent)
            remaining -= AVAudioFramePosition(count)
        }
    }

    private func emit(_ buffer: AVAudioPCMBuffer) {
        writer.write(buffer)
        transcriber?.feed(buffer)
        framesWritten += AVAudioFramePosition(buffer.frameLength)
    }

    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        guard let onLevel, let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        // Map roughly -50 dB...0 dB to 0...1.
        let db = 20 * log10(max(rms, 0.000_01))
        onLevel(max(0, min(1, (db + 50) / 50)))
    }
}
