@preconcurrency import AVFoundation
import CoreMedia

/// Which stretches of a recording have sound loud enough to be speech.
///
/// With no speech (digital silence on system audio, a quiet microphone) the speech
/// models sometimes make up a word or two ("Evet.", "I."). Those results are
/// indistinguishable from real short replies by text or confidence, but there is
/// no sound behind them, so results over silent audio are dropped.
final class VoiceActivity: @unchecked Sendable {
    static let frameDuration: TimeInterval = 0.1
    /// RMS level a frame needs to count as sound (-55 dBFS; speech is about -40 to -15).
    static let threshold: Float = 0.001_78
    /// Loud frames a result needs (shorter results need all of theirs).
    static let minimumLoudFrames = 2

    private let lock = NSLock()
    private var loud: [Bool] = []
    private var sumOfSquares: Float = 0
    private var samplesInFrame = 0

    /// Adds the next audio of the recording, in order.
    func add(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let frameSamples = max(1, Int(buffer.format.sampleRate * Self.frameDuration))
        lock.withLock {
            for i in 0..<Int(buffer.frameLength) {
                sumOfSquares += data[i] * data[i]
                samplesInFrame += 1
                if samplesInFrame == frameSamples {
                    loud.append((sumOfSquares / Float(frameSamples)).squareRoot() >= Self.threshold)
                    sumOfSquares = 0
                    samplesInFrame = 0
                }
            }
        }
    }

    /// Whether `range` (seconds from the start of the recording) has sound. Audio not
    /// seen yet counts as sound, so nothing is dropped by mistake.
    func containsSound(in range: CMTimeRange) -> Bool {
        guard range.isValid, range.start.isNumeric, range.end.isNumeric else { return true }
        let first = max(0, Int(range.start.seconds / Self.frameDuration))
        let last = max(first, Int((range.end.seconds / Self.frameDuration).rounded(.up)) - 1)
        return lock.withLock {
            guard last < loud.count else { return true }
            let frames = loud[first...last]
            return frames.count(where: \.self) >= min(Self.minimumLoudFrames, frames.count)
        }
    }

    /// The activity of a whole audio file.
    static func scan(_ url: URL) throws -> VoiceActivity {
        let activity = VoiceActivity()
        let file = try AVAudioFile(forReading: url)
        let capacity = AVAudioFrameCount(file.processingFormat.sampleRate)
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { break }
            try file.read(into: buffer)
            activity.add(buffer)
        }
        return activity
    }
}
