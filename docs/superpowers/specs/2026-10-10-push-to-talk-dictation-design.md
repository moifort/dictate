# Dictate — push-to-talk dictation for macOS

Date: 2026-10-10

## Goal

Hold `fn`, speak, release: the speech is transcribed locally, lightly cleaned up
by Claude (using the user's Claude subscription), and typed into the focused
text field of any app. Daily use covers short messages, prompts for AI/dev
tools, and long-form text, with a lot of French/English dev jargon (CI/CD,
push, merge, PR…).

## Decisions

| Topic | Decision |
|---|---|
| Platform | Native Swift/SwiftUI menu bar app (`LSUIElement`), macOS 27, Apple Silicon |
| Trigger | `fn` key, push-to-talk (hold to record, release to process) |
| Live display | None. Text appears only once transcription + enhancement are done |
| Transcription | Local, WhisperKit, `large-v3-turbo`, language forced to French, vocabulary as prompt only on request (each prompt token costs a decoder pass, ~2 s for the default list) |
| Enhancement | Claude Haiku through the official `claude` CLI (subscription), pre-warmed process |
| Local LLM fallback | None. On Claude failure, the raw Whisper transcript is used |
| Enhancement level | Light cleanup + light per-app tone adaptation, no rewriting |
| Insertion | Pasteboard + simulated `Cmd+V`, then pasteboard restored |
| No focused field | Text left in the pasteboard, clipboard icon shown in the indicator |

Rejected: Python script (fragile permissions/packaging), forking VoiceInk
(inherited code base), API key (user wants the subscription), local LLM.

## Architecture

```
fn ──► HotkeyMonitor ──► DictationController (state machine)
                           │
        ┌──────────────────┼──────────────────────┐
        ▼                  ▼                      ▼
  AudioRecorder       Transcriber             Enhancer
  (mic → memory,      protocol →              protocol →
   16 kHz mono)       WhisperKitTranscriber   ClaudeCLIEnhancer (pre-warmed)
                                                  │
                                                  ▼
                                   FocusInspector + TextInserter
```

Units, each with one responsibility:

- **HotkeyMonitor** — CGEventTap on `flagsChanged`/`keyDown`. Emits `pressed`
  and `released`. A press shorter than 0.3 s, or `fn` combined with another
  key, emits `cancelled` instead of `released`. Pure decision logic
  (`FnKeyGesture`) is separated from the event tap for testing.
- **AudioRecorder** — AVAudioEngine input tap, converted to 16 kHz mono
  `Float`, kept in memory. Publishes the current level (RMS) for the indicator.
- **Transcriber** (protocol) — `transcribe(samples:vocabulary:) async throws -> String`.
  Implementation `WhisperKitTranscriber`: model loaded at launch and kept in
  memory; first launch downloads the model.
- **Enhancer** (protocol) — `enhance(text:context:) async throws -> String`.
  Implementation `ClaudeCLIEnhancer`: keeps exactly one `claude -p` process
  started in advance (`--model haiku --tools "" --setting-sources ""
  --input-format stream-json --output-format stream-json --system-prompt …`),
  sends one user message, reads the `result` event, lets the process exit,
  then immediately starts the next one. Timeout 8 s.
- **ClaudeCLILocator** — finds the CLI: user override, then `PATH`
  (`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`), then the newest
  version bundled under `~/Library/Application Support/Claude/claude-code/<version>/*/claude.app/Contents/MacOS/claude`.
- **PromptBuilder** — builds the system prompt from the vocabulary and the
  app category.
- **AppCategory** — classifies the frontmost app bundle id into `code`
  (terminals, IDEs, Claude), `mail`, `chat`, `other`.
- **FocusInspector** — Accessibility API: is the focused element an editable
  text element? Enables `AXManualAccessibility` on Electron apps.
- **TextInserter** — pasteboard write, `Cmd+V`, pasteboard restore after a
  short delay; or pasteboard-only mode.
- **DictationController** — `idle → recording → transcribing → enhancing →
  inserting → idle`. Owns error handling. Ignores new presses while busy.
- **RecordingIndicator** — non-activating, click-through `NSPanel`, small
  horizontal pill at the bottom centre of the screen, all spaces and over
  full-screen apps. Visible only while `fn` is held (red dot + level-driven
  wave) and while processing (subtle animation) until the text is inserted.
  Clipboard case: 📋 icon for ~1.5 s. Claude failure: additional orange dot.
- **Settings** — enhancement on/off, `claude` path (auto-detected, "Test"
  button showing latency), vocabulary (one term per line, pre-filled with dev
  jargon), launch at login.

## Dictation flow

1. `fn` pressed → remember frontmost app, start mic, show indicator (recording).
2. `fn` released → stop mic, indicator switches to processing.
3. Whisper transcribes (~1 s).
4. Raw text + app category sent to the pre-warmed `claude` process (~3.5 s).
5. If a focused editable field exists → paste and restore the pasteboard;
   otherwise leave the text in the pasteboard and show 📋. Hide indicator.
   Start the next `claude` process in the background.

## Error handling

| Situation | Behaviour |
|---|---|
| Press < 0.3 s, `fn`+key, or empty audio | Nothing inserted, indicator hidden |
| Whisper returns nothing | Nothing inserted |
| Claude error or > 8 s | Raw transcript used, orange dot |
| CLI missing / not logged in | Raw transcript, menu bar alert with instructions |
| App switched during processing | Insert into whatever is focused at insertion time |
| `fn` pressed while busy | Ignored |
| Missing Microphone/Accessibility permission | Onboarding window pointing to System Settings |

## Enhancement prompt

System prompt: light cleanup only — punctuation, capitalisation, remove
hesitations and repetitions, fix technical terms using the vocabulary, keep
the original language and wording, never answer or comment the content,
output only the corrected text. One extra line per app category:
code → raw and technical; mail → slightly more polished; chat → natural;
other → neutral. The dictated text is wrapped in tags so it is never mistaken
for an instruction.

## Testing

- Unit: `FnKeyGesture`, `DictationController` with fake transcriber /
  enhancer / inserter / focus inspector, `AppCategory`, `PromptBuilder`,
  `ClaudeCLILocator`, fallback on error and timeout.
- Integration: `ClaudeCLIEnhancer` against a fake `claude` script (success,
  timeout, error, malformed output).
- Manual checklist: Terminal, VS Code, Slack, Chrome, Mail, Claude, no-field
  case (Finder/desktop).

## Commits

1. `docs: add push-to-talk dictation design`
2. `chore: scaffold Dictate menu bar app with XcodeGen`
3. `feat(core): add fn key gesture, app category and prompt builder`
4. `feat(core): add dictation controller state machine`
5. `feat(enhancer): add pre-warmed Claude CLI enhancer and locator`
6. `feat(transcriber): add WhisperKit transcriber`
7. `feat(system): add fn event tap, audio recorder, focus inspector and text inserter`
8. `feat(ui): add recording indicator, menu bar and settings`
