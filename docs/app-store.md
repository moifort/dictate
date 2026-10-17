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

## One-time steps in App Store Connect

1. **Create the app**: Apps, +, New App, platform macOS, name "Dictate",
   bundle ID `com.polyforms.dictate`, SKU `polyforms-dictate-macos`, primary
   language French or English.
2. **Pricing**: free, all territories.
3. **App Privacy**: Data Not Collected, except Diagnostics (crash data via
   Sentry, not linked to the user, no tracking).
4. **Listing**: description, keywords, support URL
   `https://github.com/moifort/dictate/issues`, marketing URL
   `https://moifort.github.io/dictate/`, screenshots at 2880×1800 or
   1440×900 (setup window, settings, the pill over an app).
5. **Upload a build**: push a tag once the secrets are set, or run
   `scripts/build-app-store.sh --upload` on the Mac. Wait for it to be
   processed, then pick it in the version page.
6. **App Review notes** (Accessibility is the usual rejection reason, explain it):
   > Dictate is push-to-talk dictation. It needs Input Monitoring to see the
   > dictation key being held (listen-only event tap, nothing is modified),
   > and Accessibility to paste the transcribed text into the focused field
   > of the frontmost app and read that field's surrounding text so the
   > on-device model keeps the user's names and tone. Audio and text never
   > leave the Mac: transcription runs locally (Parakeet) and the cleanup
   > uses Apple Intelligence on device. To test: grant the permissions in
   > the setup window, focus any text field, hold Control, speak, release.
7. **Submit for review**.

Once the app is live, add the App Store badge next to the download button on
the site and in the README.
