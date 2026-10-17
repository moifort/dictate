# Dictate

[![Latest release](https://img.shields.io/github/v/release/moifort/dictate?label=release)](https://github.com/moifort/dictate/releases/latest)
[![macOS 27, Apple Silicon](https://img.shields.io/badge/macOS-27%20%C2%B7%20Apple%20Silicon-black?logo=apple)](#get-it)
[![Homebrew](https://img.shields.io/badge/brew-moifort%2Ftap%2Fdictate-orange?logo=homebrew)](#get-it)
[![MIT license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

**Hold `control`, speak, release: your words appear wherever you are typing.**

Dictate is push-to-talk dictation for the Mac. It works in any app — mail,
notes, chat, code editor, terminal — and turns what you say into clean,
ready-to-send text.

<p align="center">
  <img src="docs/assets/demo.gif" width="800" alt="Dictating an email in Mail: holding control shows a pill with the voice waves, releasing shows a spinner while the AI reviews the sentence, then the clean text appears at the cursor">
</p>

## What it does

- **Push-to-talk on `control`** (or `fn`, in Settings). Hold the key while you
  speak, release it when you are done. No window to open, no button to click.
- **Text lands at the cursor.** The sentence is typed into whatever field has
  focus. If none does, it waits in the clipboard, ready to paste.
- **Clean text, not a raw transcript.** Hesitations ("euh", "um"), repetitions
  and false starts are removed, punctuation and capitals are fixed, misheard
  technical terms are corrected. Your words and meaning stay as you said them.
- **Adapts to where you are.** The tone of the cleanup follows the app: a bit
  more polished in a mail, direct in a chat, raw and technical in a code editor
  or a terminal.
- **Private by design.** Speech is transcribed on your Mac with Parakeet; the
  audio never leaves it. The cleanup is done by Claude through your own Claude
  subscription when Claude Code is installed and signed in, or else by Apple Intelligence's
  on-device model, so nothing leaves the Mac. Pick either in Settings, or turn
  the cleanup off entirely. Crashes and errors are reported to Sentry without
  any of your text.
- **Your language, your words.** Pick the dictation language among 25
  European languages and add your own
  vocabulary — names, jargon, product terms — so they come out spelled right.
  The app itself speaks English and French, following your Mac's language;
  the dictation language starts as your Mac's even when the interface falls
  back to English.
- **Discreet.** A small pill at the bottom of the screen shows that Dictate is
  listening, then working, and disappears.
- **Your numbers.** A statistics window charts words, dictations, speaking
  pace and the delay before the text appears, by day, week or year. The
  delay chart tells which model did the cleanup, so a day offline shows Apple
  Intelligence standing in for Claude.

## Get it

The website, [moifort.github.io/dictate](https://moifort.github.io/dictate/),
shows what a dictation looks like and links to the latest download.

Download the latest `Dictate-<version>.dmg` from
[Releases](https://github.com/moifort/dictate/releases/latest), open it, drag
Dictate onto Applications and launch it. A short setup walks you through the
permissions. Dictate then keeps itself up to date.

Or, with [Homebrew](https://brew.sh):

```bash
brew install --cask moifort/tap/dictate
```

Requires macOS 27 on Apple Silicon.

## License

Dictate is made by Polyforms and released under the [MIT License](LICENSE).
