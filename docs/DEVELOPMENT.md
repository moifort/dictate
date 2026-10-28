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

The Parakeet integration tests only run once the model
has been downloaded by the app; the vocabulary boosting ones also need the
CTC model, downloaded when the setting is turned on.

## Localization

The app speaks French and English. Strings are written in French in the code
and translated in the String Catalogs `Dictate/Resources/Localizable.xcstrings`
and `InfoPlist.xcstrings`. The bundle's development region is English, so
every Mac not set to French gets English; for French not to fall back to
English as well, every key carries its French value explicitly.

Text shown from a `String` variable is not localized by SwiftUI: build it with
`String(localized:)`, or type the property as `LocalizedStringKey`. After
adding strings, build with `SWIFT_EMIT_LOC_STRINGS=YES` and merge them into
the catalog (Xcode does it on build; on the command line, `xcrun xcstringstool
sync` with the `.stringsdata` files from the build), then give each new key
its French and English values. The tests run in French (`language: fr` in the
scheme), since some of them read user-facing text.

The disk image's background is one picture for every Mac: its instruction is
written in English, then French.

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

  The disk image is laid out by [scripts/build-dmg.sh](../scripts/build-dmg.sh):
  a Finder window with the app, an arrow and the Applications alias over a
  background painted by `scripts/dmg/render-background.swift`. To check it on
  a local Release build:

  ```bash
  scripts/build-dmg.sh build/Build/Products/Release/Dictate.app Dictate.dmg && open Dictate.dmg
  ```

Repository secrets for a signed, notarized build (without them the release is
ad-hoc signed and Gatekeeper asks for right-click → Open):

| Secret | Content |
|---|---|
| `DEVELOPER_ID_P12` | "Developer ID Application" certificate and key, `.p12` in base64 |
| `DEVELOPER_ID_P12_PASSWORD` | Password of that `.p12` |
| `ASC_KEY_ID`, `ASC_ISSUER_ID` | App Store Connect API key, used by `notarytool` |
| `ASC_KEY_P8` | Content of that key's `.p8` file |
| `SENTRY_AUTH_TOKEN` | Sentry token with `project:releases` and `project:write`, to upload the dSYMs |

## Error reporting

Release builds send caught errors and crashes to Sentry, project
`dictate-macos` in the `polyforms` organization, through `ErrorReporter`
([Dictate/App/ErrorReporter.swift](../Dictate/App/ErrorReporter.swift)).
Every `catch` in the app goes through it, with a message saying what was being
attempted and a `category` tag (`recorder`, `transcriber`, `enhancer`,
`updater`, `stats`…). The dictation outcomes and model loads are breadcrumbs,
and the settings that matter (engine, key, language, Claude on or off) are
tags on every event.

Nothing the user said or wrote is ever sent: no audio, no transcript, no
field context. Debug builds and the test host never report anything, so a
development session cannot pollute the project.

Without the `SENTRY_AUTH_TOKEN` secret the release workflow skips the dSYM
upload and crashes show addresses instead of function names.

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
   macOS opens the emoji picker or its own dictation. Only needed when the
   push-to-talk key is `fn` (Settings → Dictée → Touche); `control` is the default.
6. The transcription model (~630 MB) downloads into
   `~/Library/Application Support/Dictate/Models`, with its progress shown.
7. The `claude` CLI, optional: dictation also works without Claude.

The last page has a scratch field to try a dictation end to end.

## How it works

| Step | Component |
|---|---|
| `fn` or `control` held / released | `FnKeyMonitor` → `FnKeyGesture` |
| Microphone → 16 kHz mono | `AudioRecorder` |
| Local transcription | `SwitchableTranscriber`, routing to `ParakeetTranscriber` (Parakeet TDT Ultra through FluidAudio, 25 European languages, no vocabulary prompt), the only engine. Only the active engine's model stays in memory. |
| Vocabulary boosting (experimental, off by default) | `VocabularyBooster`: FluidAudio's CTC keyword spotting with Parakeet CTC 110M (~100 MB, in `Models/parakeet-ctc-110m-coreml`) rescores Parakeet's transcript against the vocabulary before Claude. Never waits for the model, falls back to the plain transcript on any failure. |
| Cleanup | `ClaudeCLIEnhancer`: one pre-warmed `claude -p --model claude-haiku-4-5` process per dictation (pinned: Haiku 5.5 thinks) |
| Insertion | `FocusInspector` + `TextInserter` (paste then restore the pasteboard, or pasteboard only when no field has focus) |
| Orchestration | `DictationController` |
| Bottom-centre pill | `RecordingIndicator` |
| Statistics (menu → Statistiques…) | `DictationHistory` → `DictationSeries` (one column per hour, day, week or month of the picked period) and `DictationStats` (the week against the four before) → `StatsView`, laid out like a Health app measure |

Every inserted dictation appends one JSON line — date, word count, audio
length, transcription, Claude and insertion times, never the text — to
`~/Library/Application Support/Dictate/Statistics/<bundle id>.jsonl`, so
Debug builds keep their own history.

### Evaluation corpus

Settings → Dictée → Évaluation (off by default) keeps each pasted dictation
in `~/Library/Application Support/Dictate/Corpus/<bundle id>/`: a 16 kHz
mono WAV, and a line of `entries.jsonl` with the engine's transcript, the
inserted text and a reference. The reference is what `PostInsertionObserver`
reads back from the same field 5 s after the paste (or when the next
dictation starts), cut down to the pasted segment by `InsertedSegment`, so it
includes the user's fixes. Menu → « Évaluer le corpus » shows the pooled word
error rate (`WordErrorRate`, `CorpusEvaluation`) of each engine alone and with
Claude, split by whether vocabulary boosting rescored the transcript
(`vocabularyBoosted`, absent from older entries). An unfixed mistake counts as
correct, so both rates are lower bounds.
Nothing leaves the Mac; the settings can delete the corpus.

### Vocabulary suggestions

Settings → Lexique → « Suggérer des mots pour le vocabulaire » (off by
default) reuses the same follow-up: the controller reads the field once for
both the corpus and the suggestions. `CorrectedTerms` aligns the pasted text
with the user's version word by word (case, accents and punctuation ignored)
and keeps short replacements that look like terms and still resemble what
was heard. `RecurringTerms` also counts the names and technical words of the
text before the cursor (only read when « Lire le texte autour du curseur » is
on); one seen in 5 dictations is suggested. Pending, ignored and counted
terms live in `~/Library/Application Support/Dictate/Vocabulary/<bundle id>/suggestions.json`;
logs carry counts only. The menu and the Lexique tab offer Add / Ignore.

If Claude fails or takes longer than 8 s, the raw transcript is
inserted and the pill shows an orange dot.

### Vocabulary boosting

Settings → Lexique → « Renforcer le vocabulaire dans la transcription »
downloads Parakeet CTC 110M on first use, then rescores each transcript
against the vocabulary (`CtcVocabularyEngine`, mirroring FluidAudio's
`VocabularyBoostingSession` but reading the tokenizer from `ModelStorage`).
A replaced word gets confidence 1, so Claude does not see it as doubtful and
"fix" it back; a word the rescorer drops next to a multi-word term ("with
Argo CD" → "Argo CD") is kept. The log gives the added time per dictation:
about 200 ms for a few seconds of audio on an M1 Pro. The CTC model was
trained mostly on English: compare the corpus' WER with and without it
before turning it on by default.
