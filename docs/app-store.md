# Mac App Store

Dictate ships twice: the Developer ID build from GitHub Releases (and
Homebrew), and a sandboxed build on the Mac App Store.

## What differs in the App Store build

The `AppStore` configuration sets the `APP_STORE` flag and the
`DictateAppStore.entitlements` sandbox. `Distribution.isAppStore` then hides:

- **the Claude reviewer**: the sandbox hides the home folder, so the `claude`
  CLI cannot be found, and a child process would inherit the sandbox and could
  not read Claude Code's credentials. Apple Intelligence reviews, or nothing;
- **the updater**: the App Store installs the updates;
- **the uninstaller**: deleting the app removes its sandbox container.

Checked in a sandboxed build on 2026-10-17: the app starts, the listen-only
event tap is created, the Parakeet download and Apple Intelligence work. The
sandbox only denies the Accessibility system prompt, so the setup opens the
Accessibility pane instead. Input Monitoring (`CGRequestListenEventAccess`) and
posting `Cmd+V` are the sandbox-compatible APIs Apple added in macOS 10.15.

## Building and uploading

```bash
scripts/build-app-store.sh            # archive and export build/app-store/Dictate.pkg
scripts/build-app-store.sh --upload   # archive and upload to App Store Connect
```

Signing is automatic. Xcode created the Apple Distribution and Mac Installer
Distribution certificates on first run; the first `productbuild` asks for
keychain access to the installer key: answer "Always Allow".

## Automatic upload on each release

Every `v*` tag runs the `app-store` job of the release workflow next to the
Developer ID build: it archives the AppStore configuration with manual signing
and uploads the package to App Store Connect with `altool`. A manual run of the
workflow archives and signs but does not upload. Until the secrets below exist,
the job only prints a notice and the GitHub release goes out as before.

Secrets to add to the repository (`gh secret set NAME < file`):

| Secret | Content |
|---|---|
| `MAS_DIST_CERT_P12`, `MAS_DIST_CERT_PASSWORD` | "Apple Distribution" identity exported from Keychain Access as .p12, base64 |
| `MAS_INSTALLER_CERT_P12`, `MAS_INSTALLER_CERT_PASSWORD` | "3rd Party Mac Developer Installer" identity as .p12, base64 |
| `MAS_PROVISION_PROFILE` | a Mac App Store profile for `com.polyforms.dictate`, created in the developer portal (Profiles, +, Mac App Store Connect), base64 |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` | already set for notarization |

```bash
base64 -i distribution.p12 | gh secret set MAS_DIST_CERT_P12
```

Submitting the uploaded build for review is not automated yet: pick the
build in the version page and press "Add for Review". Automating it means a
fastlane `deliver` lane (as in the book project) with `submit_for_review` and
`automatic_release`, so each tag would reach the store with no human check.

## App Store Connect

The app record is "Dictate: Speech to Text" (`com.polyforms.dictate`, SKU
`polyforms-dictate-macos`, Apple ID 6823997461), created on 2026-10-17.

`scripts/app-store/listing.rb` sets, and can set again, the English and French
listing (name, subtitle, description, keywords, promotional text, support,
marketing and privacy URLs), the categories (Productivity, Utilities), the age
rating, the copyright, the free price and the availability in every
territory. The release workflow runs `scripts/app-store/version.rb` before each
upload so the App Store version carries the tag's number.

Left to do by hand, once (no public API):

1. **Accept the updated Apple Developer Program License Agreement** at
   developer.apple.com/account: until then no new app can be submitted.
2. **App Privacy**: Data Not Collected, except Diagnostics, Crash Data (Sentry),
   not linked to the user, not used for tracking.
3. **Screenshots**: done. Five 2880×1800 panels in
   `docs/app-store-screenshots/`, uploaded to both locales by
   `scripts/app-store/screenshots.rb`. To retake the windows, launch a Debug
   build with the App Store flag and `-ScreenshotWindow setup|stats|settings`
   (`-ScreenshotTab general|dictation|lexicon|review`,
   `-ApplePersistenceIgnoreState YES -AppleLanguages "(en)"`).
4. **App Review information**: done by `scripts/app-store/review.rb`, which
   copies the contact from Shiori and sets these notes
   (Accessibility is the usual rejection reason, explain it):
   > Dictate is push-to-talk dictation. It needs Input Monitoring to see the
   > dictation key being held (listen-only event tap, nothing is modified),
   > and Accessibility to paste the transcribed text into the focused field
   > of the frontmost app and read that field's surrounding text so the
   > on-device model keeps the user's names and tone. Audio and text never
   > leave the Mac: transcription runs locally (Parakeet) and the cleanup
   > uses Apple Intelligence on device. To test: grant the permissions in
   > the setup window, focus any text field, hold Control, speak, release.
5. **Push a tag**: the release uploads the build, then
   `scripts/app-store/submit.rb <version> <build>` attaches it and submits it
   for review, released automatically on approval.

Once the app is live, add the App Store badge next to the download button on
the site and in the README.
