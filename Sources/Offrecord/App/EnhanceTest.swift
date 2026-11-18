@preconcurrency import AVFoundation
import Foundation

/// `--enhance-test <quiet-voice> <loud-voice> <out-dir>`: simulates a quiet microphone
/// (-40 dB + noise) and a normal remote side, runs the enhancer and prints levels.
enum EnhanceTest {
    static func run(quiet: URL, loud: URL, outputDirectory: URL) async {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let mic = outputDirectory.appending(path: "mic.caf")
        let system = outputDirectory.appending(path: "system.caf")
        try? FileManager.default.removeItem(at: mic)
        try? FileManager.default.removeItem(at: system)

        // Remote talks 0-25 s, "me" talks 26-50 s (quiet, noisy) - like a dialogue.
        guard let quietSamples = samples(quiet), let loudSamples = samples(loud) else { print("read failed"); return }
        let rate = AudioFileWriter.sampleRate
        let total = Int(rate * 52)
        var micTrack = [Float](repeating: 0, count: total)
        var systemTrack = [Float](repeating: 0, count: total)
        for (i, s) in loudSamples.enumerated() where i < total { systemTrack[i] = s * 0.8 }
        let offset = Int(rate * 26)
        for i in 0..<total {
            let noise = Float.random(in: -1...1) * 0.0001 // ≈ -85 dBFS floor
            let voice = (i - offset >= 0 && i - offset < quietSamples.count) ? quietSamples[i - offset] * 0.003 : 0 // -50 dB, like the real recording
            micTrack[i] = voice + noise
        }
        write(micTrack, to: mic)
        write(systemTrack, to: system)

        let before = outputDirectory.appending(path: "before.m4a")
        let after = outputDirectory.appending(path: "after.m4a")
        do {
            try await AudioMerger.merge([mic, system], into: before) // removes inputs
            write(micTrack, to: mic)
            write(systemTrack, to: system)
            try await SpeechEnhancer.render([.init(url: mic, highPass: true), .init(url: system, highPass: false)], to: after)
        } catch {
            print("FAILED:", error.localizedDescription)
            return
        }
        for (name, url) in [("before (plain mix)", before), ("after (enhanced)", after)] {
            guard let s = samples(url) else { continue }
            let r = Float(AudioFileWriter.sampleRate)
            print(name, String(format: "| remote speech %.1f dBFS | my speech %.1f dBFS | pause/noise %.1f dBFS | peak %.1f dBFS",
                               speechLevel(s, from: 1 * r, to: 24 * r), speechLevel(s, from: 27 * r, to: 49 * r),
                               rms(s, from: 25.0 * r, to: 25.9 * r), 20 * log10(s.map(abs).max() ?? 1e-9)))
        }
    }

    /// Mono samples at the writer's rate.
    static func samples(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else { return nil }
        let converter = FormatConverter(outputFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioFileWriter.sampleRate, channels: 1, interleaved: false)!)
        guard let mono = converter.convert(buffer), let data = mono.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: data, count: Int(mono.frameLength)))
    }

    static func write(_ samples: [Float], to url: URL) {
        let writer = AudioFileWriter(url: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioFileWriter.sampleRate, channels: 1, interleaved: false)!
        var index = 0
        while index < samples.count {
            let count = min(24_000, samples.count - index)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { buffer.floatChannelData![0][i] = samples[index + i] }
            writer.write(buffer)
            index += count
        }
        writer.close()
    }

    static func rms(_ s: [Float], from: Float, to: Float) -> Float {
        let a = Int(from), b = min(Int(to), s.count)
        guard b > a else { return -120 }
        let power = s[a..<b].reduce(0) { $0 + Double($1 * $1) } / Double(b - a)
        return Float(10 * log10(max(power, 1e-12)))
    }

    /// Mean level of the louder half of 50 ms windows (speech, not pauses).
    static func speechLevel(_ s: [Float], from: Float, to: Float) -> Float {
        let w = Int(AudioFileWriter.sampleRate * 0.05)
        var levels: [Float] = []
        var i = Int(from)
        while i + w < min(Int(to), s.count) {
            levels.append(rms(s, from: Float(i), to: Float(i + w)))
            i += w
        }
        let loud = levels.sorted().suffix(levels.count / 2)
        return loud.isEmpty ? -120 : loud.reduce(0, +) / Float(loud.count)
    }
}
