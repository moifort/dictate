# Development

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

Debug builds use the `com.thibautmottet.dictate.dev` identifier, so they ask
for their own permissions and settings instead of overwriting those of the
installed release: macOS ties each privacy grant to the signature it was given
to.

Tests:

```bash
xcodebuild -project Dictate.xcodeproj -scheme Dictate -derivedDataPath build -destination 'platform=macOS' test
```

The Whisper and Parakeet integration tests only run once the matching model
has been downloaded by the app.

## Updates

Dictate checks GitHub releases shortly after launch and every six hours. A
newer release is installed automatically (Settings → Général → "Installer les mises à jour
automatiquement", on by default) or offered in the menu. The downloaded
bundle is verified with `codesign` — same identifier, and same Team ID when the
running copy is signed with a real certificate — before it replaces the
installed one and the app relaunches. Copies run from a build folder never
update themselves.

## CI and releases

- **Tests** ([test.yml](../.github/workflows/test.yml)) run on every push to
  `main` and on pull requests, on GitHub's `xcode-27` runner (macOS 27).
- **Releases** ([release.yml](../.github/workflows/release.yml)) run on every
  `v*` tag: tests, Release build, Developer ID signing, notarization, then a
  GitHub release with `Dictate-<version>.dmg` for manual installs and
  `Dictate-<version>.zip` for the in-app updater. The notes come from the tag
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
It looks like a macOS setup assistant: a welcome page, then one checklist
page with every step. The step being worked on is unfolded with its
explanation and buttons; a step ticks as soon as macOS grants it, polled
every second since macOS does not notify permission changes, and the next
missing one unfolds. "Continuer" enables once the list is complete. A fresh
install opens on the welcome page, a resumed setup on the checklist.

1. **Dictation language**, taken from macOS, confirmed with a button.
2. **Microphone** permission.
3. **Input Monitoring** permission, to watch the push-to-talk key.
4. **Accessibility** permission, to detect the focused field and paste.
5. **System Settings → Keyboard → "Press 🌐 key to": Do Nothing**, otherwise
   macOS opens the emoji picker or its own dictation. Not needed when the
   push-to-talk key is `control` (Settings → Dictée → Touche).
6. The transcription model (~630 MB) downloads into
   `~/Library/Application Support/Dictate/Models`, with its progress shown.
7. The `claude` CLI, optional: dictation also works without Claude.

The last page has a scratch field to try a dictation end to end.

## How it works

| Step | Component |
|---|---|
| `fn` or `control` held / released | `FnKeyMonitor` → `FnKeyGesture` |
| Microphone → 16 kHz mono | `AudioRecorder` |
| Local transcription | `SwitchableTranscriber`, routing to the engine picked in Settings → Dictée: `ParakeetTranscriber` (Parakeet TDT Ultra through FluidAudio, default, 25 European languages, no vocabulary prompt) or `WhisperKitTranscriber` (large-v3 turbo, every language, takes the vocabulary as a prompt). Only the active engine's model stays in memory. |
| Cleanup | `ClaudeCLIEnhancer`: one pre-warmed `claude -p --model haiku` process per dictation |
| Insertion | `FocusInspector` + `TextInserter` (paste then restore the pasteboard, or pasteboard only when no field has focus) |
| Orchestration | `DictationController` |
| Bottom-centre pill | `RecordingIndicator` |
| Statistics (menu → Statistiques…) | `DictationHistory` → `DictationSeries` (one column per hour, day, week or month of the picked period) and `DictationStats` (the week against the four before) → `StatsView`, laid out like a Health app measure |

Every inserted dictation appends one JSON line — date, word count, audio
length, transcription, Claude and insertion times, never the text — to
`~/Library/Application Support/Dictate/Statistics/<bundle id>.jsonl`, so
Debug builds keep their own history.

If Claude fails or takes longer than 8 s, the raw transcript is
inserted and the pill shows an orange dot.
