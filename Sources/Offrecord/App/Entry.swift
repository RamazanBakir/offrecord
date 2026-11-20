@preconcurrency import AVFoundation
import Foundation

/// Entry point. `--selftest <audio-file> [locale]` runs the transcription and
/// note pipeline headless (file mode and simulated live mode) and prints the result.
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--version") {
            print("Offrecord \(AppInfo.version) (\(AppInfo.build))")
            exit(0)
        }
        if args.contains("--check-update") {
            Task {
                do {
                    let latest = try await UpdateChecker.fetchLatest()
                    let newer = UpdateChecker.isVersion(latest.version, newerThan: AppInfo.version)
                    print("running \(AppInfo.version), latest \(latest.version): \(newer ? "update available" : "up to date") \(latest.pageURL)")
                } catch { print("check failed:", error) }
                exit(0)
            }
            RunLoop.main.run()
        }
        if let index = args.firstIndex(of: "--selftest"), args.count > index + 1 {
            let url = URL(filePath: args[index + 1])
            let locale = Locale(identifier: args.count > index + 2 ? args[index + 2] : "tr_TR")
            Task {
                await SelfTest.run(url: url, locale: locale)
                exit(0)
            }
            RunLoop.main.run()
        } else if let index = args.firstIndex(of: "--enhance-file"), args.count > index + 1 {
            let url = URL(filePath: args[index + 1])
            Task {
                do { try await SpeechEnhancer.enhanceInPlace(url); print("enhanced") } catch { print("FAILED:", error) }
                exit(0)
            }
            RunLoop.main.run()
        } else if args.contains("--detector-test") {
            MainActor.assumeIsolated { DetectorTest.run() }
            exit(0)
        } else if let index = args.firstIndex(of: "--enhance-test"), args.count > index + 3 {
            let urls = args[(index + 1)...(index + 3)].map { URL(filePath: $0) }
            Task {
                await EnhanceTest.run(quiet: urls[0], loud: urls[1], outputDirectory: urls[2])
                exit(0)
            }
            RunLoop.main.run()
        } else if let index = args.firstIndex(of: "--recovery-test"), args.count > index + 1 {
            if args[index + 1] == "crash", args.count > index + 2 {
                let url = URL(filePath: args[index + 2])
                MainActor.assumeIsolated { RecoveryTest.crash(audio: url) }
            } else {
                Task { @MainActor in
                    await RecoveryTest.recover()
                    exit(0)
                }
                RunLoop.main.run()
            }
        } else if let index = args.firstIndex(of: "--screen-assembly-test"), args.count > index + 1 {
            let url = URL(filePath: args[index + 1])
            Task {
                await ScreenAssemblyTest.run(directory: url)
                exit(0)
            }
            RunLoop.main.run()
        } else if let index = args.firstIndex(of: "--delete-test"), args.count > index + 1 {
            let url = URL(filePath: args[index + 1])
            MainActor.assumeIsolated { Snapshot.deleteTest(outputDirectory: url) }
            exit(0)
        } else if let index = args.firstIndex(of: "--showcase"), args.count > index + 1 {
            let url = URL(filePath: args[index + 1])
            MainActor.assumeIsolated { Showcase.run(outputDirectory: url) }
            exit(0)
        } else if let index = args.firstIndex(of: "--snapshot"), args.count > index + 1 {
            let url = URL(filePath: args[index + 1])
            MainActor.assumeIsolated { Snapshot.run(outputDirectory: url) }
            exit(0)
        } else {
            Localizer.shared.applyToSystemComponents()
            OffrecordApp.main()
        }
    }
}

enum SelfTest {
    static func run(url: URL, locale: Locale) async {
        print("== File transcription (\(locale.identifier))")
        do {
            let segments = try await FileTranscriber.transcribe(url: url, locale: locale) { print("  ..", $0) }
            segments.forEach { print("  [\($0.start.clockString)] \($0.text)") }
        } catch {
            print("  FAILED:", error.localizedDescription)
        }

        print("== Simulated live pipeline")
        let collected = Collected()
        do {
            let output = FileManager.default.temporaryDirectory.appending(path: "offrecord-selftest.caf")
            try? FileManager.default.removeItem(at: output)
            let pipeline = AudioPipeline(speaker: .room, fileURL: output)
            let transcriber = try await LiveTranscriber.start(speaker: .room, locale: locale, farField: false) { _, chunk in
                guard chunk.isFinal else { return }
                for segment in SentenceBuilder.segments(from: chunk, speaker: .room, locale: locale) {
                    collected.append(segment)
                }
            }
            pipeline.attach(transcriber: transcriber)
            pipeline.begin(at: Date())

            let file = try AVAudioFile(forReading: url)
            let frames: AVAudioFrameCount = 4800
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { break }
                try file.read(into: buffer, frameCount: frames)
                pipeline.consume(buffer)
            }
            await transcriber.finish()
            pipeline.finish()
            collected.segments.forEach { print("  [\($0.start.clockString)] \($0.text)") }
            let written = try AVAudioFile(forReading: output)
            print("  wrote \(output.lastPathComponent): \(Double(written.length) / written.fileFormat.sampleRate)s")

            print("== Merge")
            let copy = output.deletingLastPathComponent().appending(path: "offrecord-selftest-2.caf")
            let merged = output.deletingLastPathComponent().appending(path: "offrecord-selftest-merged.m4a")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: output, to: copy)
            try await AudioMerger.merge([output, copy], into: merged)
            let mergedFile = try AVAudioFile(forReading: merged)
            print("  merged: \(Double(mergedFile.length) / mergedFile.fileFormat.sampleRate)s, inputs removed: \(!FileManager.default.fileExists(atPath: copy.path))")

            print("== Notes")
            let segments = collected.segments
            let notes = await NoteGenerator.generate(transcript: segments, manualNotes: [], locale: locale)
            print("  engine:", notes.engine)
            print("  summary:", notes.summary)
            print("  keyPoints:", notes.keyPoints)
            print("  decisions:", notes.decisions)
            print("  actions:", notes.actionItems)
            print("  questions:", notes.questions)
            print("== Markdown")
            let meta = SessionMeta(id: UUID(), title: "Selftest", kind: .onlineMeeting, startedAt: .now, duration: 25,
                                   options: SessionKind.onlineMeeting.defaultOptions, localeIdentifier: locale.identifier)
            print(MarkdownRenderer.render(meta: meta, notes: notes, manualNotes: [ManualNote(at: 12, text: "Ali'ye hatırlat")], transcript: segments))
        } catch {
            print("  FAILED:", error.localizedDescription)
        }
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TranscriptSegment] = []
    var segments: [TranscriptSegment] { lock.withLock { storage } }
    func append(_ segment: TranscriptSegment) { lock.withLock { storage.append(segment) } }
}
