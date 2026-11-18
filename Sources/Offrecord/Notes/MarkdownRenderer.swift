import Foundation

/// Renders a session as a portable Markdown file (notes.md).
enum MarkdownRenderer {
    static func render(meta: SessionMeta, notes: GeneratedNotes?, manualNotes: [ManualNote], transcript: [TranscriptSegment]) -> String {
        let date = meta.startedAt.formatted(.dateTime.locale(AppLanguage.current.locale).day().month(.wide).year().hour().minute())
        var out = ["# \(meta.title)", "", "\(meta.kind.title) · \(date) · \(meta.duration.clockString)", ""]
        if let attendees = meta.attendees, !attendees.isEmpty {
            out += [L("Attendees: %@", attendees.joined(separator: ", ")), ""]
        }

        if let notes, !notes.isEmpty {
            section(L("Summary"), notes.summary, into: &out, bullet: false)
            section(L("Key topics"), notes.keyPoints, into: &out)
            section(L("Decisions"), notes.decisions, into: &out)
            if !notes.actionItems.isEmpty {
                out += ["## " + L("Action items"), ""] + notes.actionItems.map { "- [\(notes.isDone($0) ? "x" : " ")] \($0)" } + [""]
            }
            section(L("Open questions"), notes.questions, into: &out)
            out.append("_" + L("Notes engine: %@", NoteGenerator.engineLabel(notes.engine)) + "_")
            out.append("")
        }

        if !manualNotes.isEmpty {
            out.append("## " + L("My notes"))
            out.append("")
            for note in manualNotes {
                out.append("- `\(note.at.clockString)` \(note.isBookmark ? "★ " : "")\(note.text)")
            }
            out.append("")
        }

        if !transcript.isEmpty {
            out.append("## " + L("Transcript"))
            out.append("")
            var lastSpeaker: Speaker?
            for segment in transcript {
                if segment.speaker != lastSpeaker {
                    out.append("")
                    out.append("**\(meta.label(for: segment.speaker))** `\(segment.start.clockString)`")
                    lastSpeaker = segment.speaker
                }
                out.append(segment.text)
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    private static func section(_ title: String, _ items: [String], into out: inout [String], bullet: Bool = true, checkbox: Bool = false) {
        guard !items.isEmpty else { return }
        out.append("## \(title)")
        out.append("")
        if bullet {
            out += items.map { checkbox ? "- [ ] \($0)" : "- \($0)" }
        } else {
            out.append(items.joined(separator: " "))
        }
        out.append("")
    }
}
