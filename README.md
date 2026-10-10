# Dictate

Push-to-talk dictation for macOS: hold `fn`, speak, release. Speech is
transcribed locally with Whisper, lightly cleaned up by Claude Haiku through
your Claude subscription, then typed into the focused field.

Design: [docs/superpowers/specs/2026-10-10-push-to-talk-dictation-design.md](docs/superpowers/specs/2026-10-10-push-to-talk-dictation-design.md)

## Requirements

- macOS 27, Apple Silicon, Xcode 27
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Claude Code signed in with your Claude account (the CLI bundled with the
  Claude desktop app is detected automatically)

## Build and run

```bash
xcodegen generate
xcodebuild -project Dictate.xcodeproj -scheme Dictate -derivedDataPath build build
open build/Build/Products/Debug/Dictate.app
```

Tests:

```bash
xcodebuild -project Dictate.xcodeproj -scheme Dictate -derivedDataPath build -destination 'platform=macOS' test
```

The Whisper integration test only runs once the model has been downloaded by
the app.

## First launch

An onboarding window opens at every launch until everything below is ready.
It shows one step at a time and moves on by itself as each one is granted:

1. **Microphone** permission.
2. **Input Monitoring** permission, to watch the `fn` key.
3. **Accessibility** permission, to detect the focused field and paste.
4. **System Settings → Keyboard → "Press 🌐 key to": Do Nothing**, otherwise
   macOS opens the emoji picker or its own dictation.
5. The Whisper model (~630 MB) downloads into
   `~/Library/Application Support/Dictate/Models`, with its progress shown.
6. The `claude` CLI, optional: dictation also works without Claude.

The last page has a scratch field to try a dictation end to end.

## How it works

| Step | Component |
|---|---|
| `fn` held / released | `FnKeyMonitor` → `FnKeyGesture` |
| Microphone → 16 kHz mono | `AudioRecorder` |
| Local transcription | `WhisperKitTranscriber` (large-v3 turbo) |
| Cleanup | `ClaudeCLIEnhancer`: one pre-warmed `claude -p --model haiku` process per dictation |
| Insertion | `FocusInspector` + `TextInserter` (paste then restore the pasteboard, or pasteboard only when no field has focus) |
| Orchestration | `DictationController` |
| Bottom-centre pill | `RecordingIndicator` |

If Claude fails or takes longer than 8 s, the raw Whisper transcript is
inserted and the pill shows an orange dot.
