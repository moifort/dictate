# TODO

Improvements to transcript quality and latency, in the recommended order.

## Quick wins

- [ ] **Keep recording after `fn` is released** — the recorder stops the
  instant `fn` goes up (`DictationController`, `.released`), which often clips
  the last syllable. Keep capturing 200-300 ms before stopping.
- [x] **Read the preceding text while Parakeet transcribes** — today the
  accessibility read runs on release, before transcription starts, and can
  take up to the 0.5 s messaging timeout in Electron apps. Run it concurrently
  with the transcription.

## Measure before tuning

- [x] **Evaluation corpus from real dictations** — opt-in setting that keeps
  each dictation's audio locally, plus the field's text a few seconds after
  insertion (i.e. with the user's own fixes) as the reference. With 50-100
  real dictations, compute the word error rate of Parakeet alone and of
  Parakeet + Haiku. Parakeet's accuracy has only been checked on synthesized
  voices so far.

## Transcript quality

- [x] **Flag low-confidence words for Haiku** — FluidAudio returns a confidence
  per token (`TokenTiming.confidence`), currently unused. Mark the doubtful
  words in the user message (e.g. `<?>Kubernetis</?>`) so Haiku knows where to
  correct, and where to leave the text alone.
- [x] **Richer accessibility context**
  - [x] Browsers: read the active tab's URL to categorize web apps
    (`mail.google.com` → mail, `app.slack.com` → chat, `github.com` → code).
    Browsers all fall into `other` today.
  - [x] Window title: email subject, Slack channel, PR title — names Haiku
    can spell from.
  - [x] Field label (placeholder, description): "Subject",
    "Message #general", "Commit message".
  - [x] Text after the cursor: when dictating mid-sentence, no final period
    and no leading capital.
- [x] **Vocabulary boosting in Parakeet** — FluidAudio 0.17.7 ships CTC keyword
  spotting + rescoring (`VocabularyBoostingSession`, see
  `Documentation/ASR/CustomVocabulary.md`). It works with any TDT model,
  Ultra included, through a separate Parakeet CTC 110M model (~100 MB, ~70×
  real time). The vocabulary would then fix mangled terms from the audio
  instead of relying on Haiku guessing them. Risk: the CTC model is likely
  English-centric — validate on the evaluation corpus with French dictations.
- [x] **Self-building vocabulary** — re-read the field a few seconds after
  insertion and diff it with what was pasted; when the user fixed a term,
  suggest adding it to the vocabulary. Simpler variant: suggest the proper
  nouns that keep appearing in the preceding text.
- [ ] **Continuity between dictations** — when the previous dictation was in
  the same app less than ~2 minutes ago, send it as context (same names, same
  tu/vous).

## Latency

Haiku dominates the total (~0.9 s, against ~0.2 s for Parakeet).

- [ ] **Direct API call with thinking disabled** — Haiku 5.5 thinks ~250
  tokens through the CLI whatever is passed. Calling the API directly would
  likely save several hundred ms, but needs an API key instead of the Claude
  subscription. Decision pending.
- [ ] **Skip Haiku when it adds nothing** — short dictation, every token above
  a confidence threshold, no vocabulary term: paste Parakeet's text directly.
  Decide on the evaluation corpus (punctuation may suffer).

Not worth doing: transcribing while `fn` is held. Tried with Whisper and
reverted (commit d5dcce4); with Parakeet at ~0.2 s there is nothing left to
gain.
