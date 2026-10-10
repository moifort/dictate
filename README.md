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

## Updates

Dictate checks GitHub releases shortly after launch and every six hours. A
newer release is installed automatically (Settings → "Installer les mises à
jour automatiquement", on by default) or offered in the menu. The downloaded
bundle is verified with `codesign` — same identifier, and same Team ID when the
running copy is signed with a real certificate — before it replaces the
installed one and the app relaunches. Copies run from a build folder never
update themselves.

## CI and releases

- **Tests** ([test.yml](.github/workflows/test.yml)) run on every push to
  `main` and on pull requests, on GitHub's `xcode-27` runner (macOS 27).
- **Releases** ([release.yml](.github/workflows/release.yml)) run on every
  `v*` tag: tests, Release build, Developer ID signing, notarization, then a
  GitHub release with `Dictate-<version>.zip`. The notes come from the tag
  annotation:

  ```bash
  git tag -a v0.2.0 -m "What changes in this version"
  git push origin v0.2.0
  ```

Repository secrets for a signed, notarized build (without them the release is
ad-hoc signed and Gatekeeper asks for right-click → Open):

| Secret | Content |
|---|---|
| `DEVELOPER_ID_P12` | "Developer ID Application" certificate and key, `.p12` in base64 |
| `DEVELOPER_ID_P12_PASSWORD` | Password of that `.p12` |
| `ASC_KEY_ID`, `ASC_ISSUER_ID` | App Store Connect API key, used by `notarytool` |
| `ASC_KEY_P8` | Content of that key's `.p8` file |

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
