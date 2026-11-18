@preconcurrency import AVFoundation
import AppKit
import Foundation

/// `--recovery-test crash <audio>`: records like a live session then SIGKILLs itself.
/// `--recovery-test recover`: runs launch-time recovery and prints the result.
/// Both use the storage folder given with `-storagePath`.
@MainActor
enum RecoveryTest {
    static func crash(audio: URL) {
        let store = SessionStore()
        let meta = SessionMeta(id: UUID(), title: "Çökme testi", kind: .onlineMeeting, startedAt: .now, duration: 0,
                               options: SessionKind.onlineMeeting.defaultOptions, localeIdentifier: "tr_TR", isComplete: false)
        guard let record = try? store.createFolder(for: meta),
              let file = try? AVAudioFile(forReading: audio) else { print("setup failed"); exit(1) }
        let pipeline = AudioPipeline(speaker: .me, fileURL: record.folder.appending(path: SessionFiles.micAudio))
        pipeline.begin(at: Date())
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4800) else { break }
            try? file.read(into: buffer, frameCount: 4800)
            pipeline.consume(buffer)
        }
        // Autosaved transcript as the housekeeping task would have written it.
        try? store.save(transcript: [TranscriptSegment(speaker: .me, start: 1, end: 4, text: "Ali raporu cumaya kadar gönderecek.")], in: record)
        print("crashing with unfinished session in \(record.folder.lastPathComponent)")
        fflush(stdout)
        kill(getpid(), SIGKILL)
    }

    static func recover() async {
        let model = AppModel.shared
        print("unfinished before:", model.store.unfinished.map(\.meta.title))
        model.recoverUnfinished()
        for _ in 0..<40 where !model.store.unfinished.isEmpty || model.store.sessions.first?.hasAudio != true {
            try? await Task.sleep(for: .milliseconds(250))
        }
        for record in model.store.sessions {
            let duration = (try? await AVURLAsset(url: record.audioURL).load(.duration).seconds) ?? -1
            let files = (try? FileManager.default.contentsOfDirectory(atPath: record.folder.path).sorted()) ?? []
            print("title:", record.meta.title, "| complete:", record.meta.isComplete as Any, "| audio s:", duration)
            print("files:", files)
            print("actions:", model.store.notes(for: record)?.actionItems ?? [])
        }
    }
}
