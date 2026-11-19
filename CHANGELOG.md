# Changelog

All notable changes to Offrecord are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-11-20

First public release.

### Added

- One-click recording of the microphone and system audio (the other side of a call),
  with optional screen recording.
- Live on-device transcription with *Me* / *Them* speaker labels, using Apple's
  `SpeechAnalyzer` (`DictationTranscriber` for languages such as Turkish).
- Automatic meeting notes: summary, key topics, decisions, action items and open
  questions, written by Apple Intelligence when available and by a local rule-based
  extractor otherwise.
- To-do list that collects action items from every recording.
- Call detection that offers to record when another app starts using the microphone
  and stops automatically when the call ends.
- Voice processing during calls and per-utterance level balancing after recording.
- Calendar-based titles and attendees.
- Crash-safe recording with automatic recovery on the next launch.
- Full-text search, global shortcut (⌃⌥R), menu bar icon and floating recording bar.
- Transcription of existing audio and video files.
- English and Turkish interface, switchable in Settings.
- `install.sh` / `uninstall.sh` for building from source with a local signing certificate.

[0.1.0]: https://github.com/RamazanBakir/offrecord/releases/tag/v0.1.0
