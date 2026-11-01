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
- **the uninstaller**: deleting the app removes its sandbox container;
- **Accessibility and Input Monitoring**: App Review refused both on 2026-10-25
  (guideline 2.4.5), for an app that is not an accessibility tool. The event
  tap, `FocusInspector` and the posted `Cmd+V` are compiled out. Dictation runs
  on a Carbon global hot key, held ⌥Space (`HotKeyMonitor`, no permission), and
  the text stays in the pasteboard for the user to paste. With no field to read
  go the field context, the vocabulary suggestions and the evaluation corpus;
  the frontmost app still sets the tone of the cleanup.

The microphone button says "Continuer" here: guideline 5.1.1(iv) refuses a
button that asks for the grant before the system prompt.

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
3. **Screenshots**: done. Six 2880×1800 panels per locale, the site's
   dictation demo first, in `docs/app-store-screenshots/<locale>/`, uploaded by
   `scripts/app-store/screenshots.rb`. To retake the windows, launch a Debug
   build with the App Store flag and `-ScreenshotWindow setup|stats|settings`
   (`-ScreenshotTab general|dictation|lexicon|review`,
   `-ApplePersistenceIgnoreState YES -AppleLanguages "(en)"`).
4. **App Review information**: done by `scripts/app-store/review.rb`, which
   copies the contact from Shiori and sets notes along these lines:
   > Dictate is push-to-talk dictation. Hold Option + Space, speak, release:
   > the text is placed on the clipboard, and the user pastes it with
   > Command-V. It requests the microphone only, no longer Accessibility or
   > Input Monitoring.
5. **Push a tag**: the release uploads the build, then
   `scripts/app-store/submit.rb <version> <build>` attaches it and submits it
   for review, released automatically on approval.

Once the app is live, add the App Store badge next to the download button on
the site and in the README.
