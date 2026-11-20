import Foundation

/// Drops microphone lines that only repeat the other side: on speakers the call's
/// sound leaks into the microphone and would be transcribed twice. Apple's voice
/// processing cancels only Offrecord's own playback, not the call app's.
enum EchoFilter {
    /// How far apart (seconds) an echo and its source may be.
    static let tolerance: TimeInterval = 1.5
    /// Share of the microphone line's words that must also be in the other side's line.
    static let overlap = 0.5

    static func isEcho(_ mine: TranscriptSegment, of theirs: TranscriptSegment) -> Bool {
        guard mine.speaker == .me, theirs.speaker == .others,
              mine.start <= theirs.end + tolerance, theirs.start <= mine.end + tolerance
        else { return false }
        let myWords = Set(words(mine.text))
        guard !myWords.isEmpty else { return false }
        let shared = myWords.intersection(words(theirs.text)).count
        return Double(shared) / Double(myWords.count) >= overlap
    }

    /// The transcript without echo lines.
    static func removingEchoes(from segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let theirs = segments.filter { $0.speaker == .others }
        return segments.filter { segment in !theirs.contains { isEcho(segment, of: $0) } }
    }

    private static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}

/// Re-transcribing a call works on the mixed audio file, which has no speakers.
/// The previous transcript does (each side was transcribed separately), so every
/// new line takes the speaker whose old lines it overlaps in time.
enum SpeakerAttribution {
    /// Old lines without a duration count as this long.
    private static let minimumDuration: TimeInterval = 0.5

    static func assign(_ segments: [TranscriptSegment], from previous: [TranscriptSegment]) -> [TranscriptSegment] {
        let reference = previous.filter { $0.speaker == .me || $0.speaker == .others }
        guard !reference.isEmpty else { return segments }
        return segments.map { segment in
            var segment = segment
            segment.speaker = speaker(for: segment, in: reference)
            return segment
        }
    }

    private static func speaker(for segment: TranscriptSegment, in reference: [TranscriptSegment]) -> Speaker {
        var overlap: [Speaker: TimeInterval] = [:]
        for old in reference {
            let end = max(old.end, old.start + minimumDuration)
            let shared = min(segment.end, end) - max(segment.start, old.start)
            if shared > 0 { overlap[old.speaker, default: 0] += shared }
        }
        let mine = overlap[.me] ?? 0
        let theirs = overlap[.others] ?? 0
        if mine > 0 || theirs > 0 {
            // Both overlapping usually means the other side echoed into the microphone.
            return theirs >= mine * 0.5 ? .others : .me
        }
        let nearest = reference.min { distance($0, segment) < distance($1, segment) }
        return nearest?.speaker ?? segment.speaker
    }

    private static func distance(_ a: TranscriptSegment, _ b: TranscriptSegment) -> TimeInterval {
        max(0, max(a.start, b.start) - min(a.end, b.end))
    }
}
