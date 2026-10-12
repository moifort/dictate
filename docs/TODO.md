# TODO

Running list of what is done and what is left, one section per area. Tick an
item when it is merged on `main`; delete a section once everything in it is
done and documented.

## Onboarding

Audit of `SetupView` on 2026-10-12. Pages slide like a setup assistant, but
the slide was not coherent: the direction was read from state captured
before the navigation, and the page shown could change under the user.

### Animations

- [x] Outgoing page leaves in the right direction. `movingForward` and the
      page changed in the same transaction, so the outgoing page kept the
      transition of the *previous* navigation: after a "Continuer" then a
      back chevron, both pages moved toward the leading edge. Replaced by
      `PageSlide`, a `Transition` that reads the direction from a shared
      reference at the moment it runs.
- [x] One animation for the whole navigation, on `page`, instead of one on
      the outer `ZStack` (`index`) and one inside (`page`).
- [x] Bottom bar fixed while pages slide. Button and page dots used to live
      inside each page, so they slid with it and the dots never animated.
- [x] Model progress: `.transition(.blurReplace)` sat on the `ZStack`, not on
      the states it switches between, so they just faded.
- [x] Title and explanation crossfade when they change in place ("C'est
      fait.", "Tout est prêt").
- [ ] Check the slide on a real run: forward, back, then forward again. The
      session could not drive the window (no Accessibility grant for
      automation), so only the still pages were verified.

### Navigation

- [x] The current page was derived from the checklist until the user
      navigated: the one-second permission poll could move the page by
      itself, and a step already granted by macOS skipped the welcome page on
      a fresh install. The first page is now decided once, when the window
      opens (`SetupView.firstPage(for:)`): welcome until the language is
      confirmed, otherwise the first missing step.
- [x] `DEVELOPMENT.md` described the previous wizard: no welcome or language
      page, "moves on by itself", no back chevron.

### Not planned

- Auto-advance when the current step completes: Apple's assistants wait for
  "Continuer", and the green check is the feedback.
- Recording pill animations (`RecordingIndicator`): coherent, untouched.
