# TODO

Running list of what is done and what is left, one section per area. Tick an
item when it is merged on `main`; delete a section once everything in it is
done and documented.

## Onboarding

Audit of `SetupView` on 2026-10-12. Pages slide like a setup assistant, but
the slide was not coherent: the direction was read from state captured
before the navigation, and the page shown could change under the user.

### Animations

- [ ] Outgoing page leaves in the right direction. `movingForward` and the
      page change in the same transaction, so the outgoing page keeps the
      transition of the *previous* navigation: after a "Continuer" then a
      back chevron, both pages move toward the leading edge.
- [ ] One animation for the whole navigation. The outer `ZStack` animates on
      `index`, the inner one on `page`, with different curves.
- [ ] Bottom bar fixed while pages slide. Button and page dots live inside
      each page, so they slide with it and the dots never animate.
- [ ] Model progress: `.transition(.blurReplace)` sits on the `ZStack`, not on
      the states it switches between, so they just fade.
- [ ] "C'est fait." and the step heading swap without a transition when a
      step completes.

### Navigation

- [ ] The current page is derived from the checklist until the user
      navigates: the one-second permission poll can move the page by itself,
      and a step that was already granted skips the welcome page on a fresh
      install. Decide the first page once, when the window opens: welcome
      until the language is confirmed, otherwise the first missing step.
- [ ] `DEVELOPMENT.md` still describes the previous wizard: no welcome or
      language page, "moves on by itself", no back chevron.

### Not planned

- Auto-advance when the current step completes: Apple's assistants wait for
  "Continuer", and the green check is the feedback.
- Recording pill animations (`RecordingIndicator`): coherent, untouched.
