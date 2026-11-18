# Contributing to Offrecord

Thanks for helping! Offrecord is a small, dependency-free Swift app. Please keep
it that way: only Apple system frameworks, no network services.

## Getting started

```sh
git clone https://github.com/<your-account>/offrecord.git
cd offrecord
./scripts/install.sh        # builds, signs locally and installs to ~/Applications
```

Requirements: macOS 26+, Apple silicon, Xcode 26 or its Command Line Tools.

## Project layout

```
Sources/Offrecord/
  App/            app entry, state, recording controller, call detection, menu bar
  Capture/        microphone, system audio / screen, mixing, speech leveling
  Transcription/  SpeechAnalyzer wrappers, sentence restoration
  Notes/          note generation (Apple Intelligence + rule-based), Markdown export
  Model/          data types and on-disk storage
  Views/          SwiftUI screens
  Localization/   interface strings (English keys, Turkish table)
scripts/          install, build, signing, translation checks
```

## Before opening a pull request

- `swift build` succeeds without warnings.
- `./scripts/check-translations.sh` passes. Interface text goes through `L("English text")`;
  add the Turkish translation to `Localization/Turkish.swift` (or leave a note and
  someone will translate it).
- If you changed a screen, render it: `build/Offrecord.app/Contents/MacOS/Offrecord --snapshot /tmp/shots`.
- If you touched transcription or notes, run `--selftest <audio-file> <locale>`.
- Code, identifiers and comments are in English.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat:`, `fix:`, `docs:` …).

## Reporting bugs

Include your macOS version, Mac model, the call app you used and what you expected.
If the app crashed, attach the report from Console › Crash Reports (look for
`Offrecord`). Please do not attach recordings that contain other people's voices.

## Translations

Add a table next to `Localization/Turkish.swift`, add a case to `AppLanguage`
in `Localization/Localization.swift`, and run `./scripts/check-translations.sh`.
