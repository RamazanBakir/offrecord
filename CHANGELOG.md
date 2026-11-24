# Changelog

All notable changes to Offrecord are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Downloadable app: every release now ships `Offrecord-X.Y.Z.zip` with its SHA-256.
- Update notifications: Offrecord checks GitHub for a new release twice a day and shows a
  banner with the new version. Turn it off or check manually in Settings › About.
- New app icon and logo.
- Project website: https://ramazanbakir.github.io/offrecord/
- `scripts/release.sh` to publish a release in one command.
- Choose what to record on screen: macOS's own picker opens when a screen recording
  starts, so you can pick any display (multi-monitor setups) or a single window.
  Offrecord can reuse the last choice, and its own windows stay out of the video.
- **Change screen** while recording: pick another display or window and the video
  continues with it in the same frame (works while paused, and after a recorded
  window was closed). The audio is not interrupted.

- Automatic language detection (new default): the first sentences are transcribed in
  your system language and in English and the clearly better one is kept, separately
  for you and the other side. A language menu is on the start screen too.
- **Transcribe again** menu on every recording: detect the language or pick one, to
  fix recordings made in the wrong language. Speaker labels are kept for calls.

### Fixed

- Meetings in English were transcribed with the Turkish model (and vice versa) when
  the language setting didn't match, producing nonsense. If your language was set to
  your system language, it switches to automatic detection once.
- On speakers, the other side's words were transcribed twice (also as "Me") because
  the call leaked into the microphone. Those echo lines are now removed.
- The screen recording no longer echoes the other side of the call: its audio is now
  the same echo-cancelled, level-balanced mix as `audio.m4a` instead of the raw microphone.
- Pausing now pauses the screen video too (it used to keep recording the screen).
- Words appeared in the transcript while nobody was speaking: with silent audio the
  speech models sometimes make up a word ("Evet.", "I."). Results over silent audio
  are now dropped, live and when transcribing a file.
- Recording silently failed after reinstalling with a new signing identity: System
  Settings still showed the permissions allowed, but macOS no longer applied them.
  `install.sh` now clears the old grants when the app's signature changes.
- System audio is recorded separately from the video, so recording a single window
  never cuts the other side of the call.
- If the recorded window closes or the display is disconnected, the audio keeps
  recording and Offrecord tells you the video stopped.

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
