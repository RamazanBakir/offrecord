@preconcurrency import AVFoundation

/// Offline speech leveling and mixing.
///
/// Each input is analysed in 50 ms windows; speech windows are brought to a common
/// loudness (per utterance, up to +40 dB) while pauses get at most +6 dB so the noise
/// floor is not pumped up. The microphone gets an 80 Hz high-pass (desk rumble, fans).
/// Tracks are summed, peak-limited at -1 dBFS and encoded to AAC.
enum SpeechEnhancer {
    struct Input {
        var url: URL
        var highPass: Bool
    }

    static let targetDB: Float = -20
    static let maxBoostDB: Float = 40
    static let pauseBoostDB: Float = 6
    private static let windowSeconds = 0.05
    private static let chunkFrames: AVAudioFrameCount = 48_000

    /// Levels, mixes and encodes `inputs` (same sample rate, same timeline) into `output` (.m4a).
    static func render(_ inputs: [Input], to output: URL) async throws {
        let existing = inputs.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard !existing.isEmpty else { return }

        var tracks: [Track] = []
        for input in existing {
            tracks.append(try Track(input: input))
        }
        let sampleRate = tracks[0].sampleRate
        let length = tracks.map(\.length).max() ?? 0

        let mixed = FileManager.default.temporaryDirectory.appending(path: "offrecord-mix-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: mixed) }
        try mix(tracks, sampleRate: sampleRate, length: length, to: mixed)

        try? FileManager.default.removeItem(at: output)
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: mixed), presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try await export.export(to: output, as: .m4a)
    }

    /// Re-levels an existing finished recording in place; the original is kept as audio-original.m4a.
    static func enhanceInPlace(_ url: URL) async throws {
        let backup = url.deletingLastPathComponent().appending(path: "audio-original.m4a")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: url, to: backup)
        }
        let temporary = url.deletingLastPathComponent().appending(path: "enhanced-\(UUID().uuidString).m4a")
        try await render([Input(url: url, highPass: true)], to: temporary)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    // MARK: Analysis

    final class Track {
        let file: AVAudioFile
        let sampleRate: Double
        let length: AVAudioFramePosition
        let windowFrames: Int
        let highPass: Bool
        /// Linear gain per analysis window.
        private(set) var gains: [Float] = []
        private var filter: Biquad?

        init(input: Input) throws {
            file = try AVAudioFile(forReading: input.url)
            sampleRate = file.processingFormat.sampleRate
            length = file.length
            windowFrames = max(1, Int(sampleRate * SpeechEnhancer.windowSeconds))
            highPass = input.highPass
            gains = try analyse()
            file.framePosition = 0
            filter = highPass ? Biquad.highPass(frequency: 80, sampleRate: sampleRate) : nil
        }

        /// Reads the next chunk as filtered mono samples (zeros past the end).
        func read(_ count: Int) -> [Float] {
            var samples = [Float](repeating: 0, count: count)
            guard file.framePosition < length,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)),
                  (try? file.read(into: buffer, frameCount: AVAudioFrameCount(count))) != nil,
                  let channels = buffer.floatChannelData else { return samples }
            let channelCount = Int(buffer.format.channelCount)
            for i in 0..<Int(buffer.frameLength) {
                var sum: Float = 0
                for c in 0..<channelCount { sum += channels[c][i] }
                let mono = sum / Float(channelCount)
                samples[i] = filter?.process(mono) ?? mono
            }
            return samples
        }

        private func analyse() throws -> [Float] {
            filter = highPass ? Biquad.highPass(frequency: 80, sampleRate: sampleRate) : nil
            var levels: [Float] = []
            var accumulator: Double = 0
            var counted = 0
            while file.framePosition < length {
                let before = file.framePosition
                let chunk = read(Int(SpeechEnhancer.chunkFrames))
                let valid = Int(min(AVAudioFramePosition(chunk.count), length - before))
                if file.framePosition == before { break } // read failed, avoid looping forever
                for sample in chunk.prefix(valid) {
                    accumulator += Double(sample * sample)
                    counted += 1
                    if counted == windowFrames {
                        levels.append(Self.decibels(accumulator / Double(counted)))
                        accumulator = 0
                        counted = 0
                    }
                }
            }
            if counted > 0 { levels.append(Self.decibels(accumulator / Double(counted))) }
            return Self.gainCurve(levels: levels)
        }

        static func decibels(_ meanSquare: Double) -> Float {
            Float(10 * log10(max(meanSquare, 1e-12)))
        }

        /// Per-window linear gains from per-window levels (dB).
        static func gainCurve(levels: [Float]) -> [Float] {
            guard !levels.isEmpty else { return [] }
            let sorted = levels.sorted()
            let noiseFloor = sorted[Int(Double(sorted.count - 1) * 0.15)]
            let speechThreshold = max(noiseFloor + 8, -80)
            let isSpeech = levels.map { $0 > speechThreshold }
            guard isSpeech.contains(true) else { return [Float](repeating: 1, count: levels.count) }

            // Local speech loudness: mean power of speech windows within ±0.5 s.
            let radius = 10
            var prefixPower = [Double](repeating: 0, count: levels.count + 1)
            var prefixCount = [Int](repeating: 0, count: levels.count + 1)
            for i in levels.indices {
                let power = isSpeech[i] ? pow(10, Double(levels[i]) / 10) : 0
                prefixPower[i + 1] = prefixPower[i] + power
                prefixCount[i + 1] = prefixCount[i] + (isSpeech[i] ? 1 : 0)
            }
            var gainDB = [Float?](repeating: nil, count: levels.count)
            for i in levels.indices where isSpeech[i] {
                let lo = max(0, i - radius), hi = min(levels.count, i + radius + 1)
                let count = prefixCount[hi] - prefixCount[lo]
                let local = Float(10 * log10((prefixPower[hi] - prefixPower[lo]) / Double(max(count, 1))))
                gainDB[i] = min(max(SpeechEnhancer.targetDB - local, -6), SpeechEnhancer.maxBoostDB)
            }
            // Pauses: follow the nearest speech gain but cap the boost.
            var last: Float?
            var filled = [Float](repeating: 0, count: levels.count)
            for i in levels.indices {
                if let g = gainDB[i] { last = g }
                filled[i] = last ?? .nan
            }
            last = nil
            for i in levels.indices.reversed() {
                if let g = gainDB[i] { last = g }
                if filled[i].isNaN { filled[i] = last ?? 0 }
                if gainDB[i] == nil { filled[i] = min(filled[i], SpeechEnhancer.pauseBoostDB) }
            }
            // Smooth over ±150 ms to avoid audible steps.
            let smoothRadius = 3
            var smoothed = filled
            for i in filled.indices {
                let lo = max(0, i - smoothRadius), hi = min(filled.count - 1, i + smoothRadius)
                smoothed[i] = filled[lo...hi].reduce(0, +) / Float(hi - lo + 1)
            }
            return smoothed.map { pow(10, $0 / 20) }
        }

        /// Gain for an absolute frame, interpolated between window centres.
        func gain(at frame: Int) -> Float {
            guard !gains.isEmpty else { return 1 }
            let position = Float(frame) / Float(windowFrames) - 0.5
            let index = max(0, min(Int(position), gains.count - 1))
            let next = min(index + 1, gains.count - 1)
            let fraction = max(0, min(1, position - Float(index)))
            return gains[index] + (gains[next] - gains[index]) * fraction
        }
    }

    // MARK: Mixing

    private static func mix(_ tracks: [Track], sampleRate: Double, length: AVAudioFramePosition, to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let output = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let threshold: Float = 0.89 // -1 dBFS
        let release = Float(exp(-1 / (0.15 * sampleRate)))
        var envelope: Float = 0
        var frame = 0
        while frame < Int(length) {
            let count = min(Int(chunkFrames), Int(length) - frame)
            let chunks = tracks.map { $0.read(count) }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let out = buffer.floatChannelData?[0] else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count {
                var y: Float = 0
                for (t, track) in tracks.enumerated() {
                    y += chunks[t][i] * track.gain(at: frame + i)
                }
                // Peak limiter: instant attack, 150 ms release.
                envelope = max(abs(y), envelope * release)
                if envelope > threshold { y *= threshold / envelope }
                out[i] = y
            }
            try output.write(from: buffer)
            frame += count
        }
    }
}

/// RBJ biquad (used as an 80 Hz high-pass).
struct Biquad {
    private var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    static func highPass(frequency: Double, sampleRate: Double, q: Double = 0.707) -> Biquad {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosW = cos(w0)
        let a0 = 1 + alpha
        return Biquad(
            b0: Float((1 + cosW) / 2 / a0), b1: Float(-(1 + cosW) / a0), b2: Float((1 + cosW) / 2 / a0),
            a1: Float(-2 * cosW / a0), a2: Float((1 - alpha) / a0)
        )
    }

    private init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}
