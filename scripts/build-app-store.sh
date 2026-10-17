#!/bin/bash
# The Mac App Store build: archives the sandboxed AppStore configuration,
# signs it for distribution and either uploads it to App Store Connect or
# leaves the installer package in build/app-store.
#
#   scripts/build-app-store.sh            # archive, export build/app-store/Dictate.pkg
#   scripts/build-app-store.sh --upload   # archive and upload to App Store Connect
#
# Two ways to sign:
#
# - automatic (on the Mac): Xcode creates or downloads the Apple Distribution
#   and Mac Installer Distribution certificates and the provisioning profile,
#   with the Apple account signed in to Xcode, or with an App Store Connect API
#   key when ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH are set;
# - manual (the release workflow): MAS_PROFILE_NAME names an installed Mac App
#   Store profile, and both certificates are already in a keychain. Nothing
#   talks to the developer portal, whose provisioning endpoint fails
#   intermittently from CI.
#
# Version and build number follow the Developer ID release: the latest tag and
# the commit count, so each upload carries a higher build number.
set -euo pipefail

cd "$(dirname "$0")/.."

DESTINATION=export
[ "${1:-}" = "--upload" ] && DESTINATION=upload

TEAM_ID=46C337T7YN
BUNDLE_ID=com.polyforms.dictate
MARKETING="${MARKETING:-$(git describe --tags --abbrev=0 --match 'v*' | sed 's/^v//')}"
BUILD="${BUILD:-$(git rev-list --count HEAD)}"
OUT=build/app-store
ARCHIVE="$OUT/Dictate.xcarchive"

AUTH=()
if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && [ -n "${ASC_KEY_PATH:-}" ]; then
  AUTH=(
    -authenticationKeyPath "${ASC_KEY_PATH/#\~/$HOME}"
    -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"
  )
fi

if [ -n "${MAS_PROFILE_NAME:-}" ]; then
  SIGNING=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="Apple Distribution"
    PROVISIONING_PROFILE_SPECIFIER="$MAS_PROFILE_NAME"
  )
  PORTAL=()
  EXPORT_SIGNING="<key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>installerSigningCertificate</key><string>3rd Party Mac Developer Installer</string>
  <key>provisioningProfiles</key><dict><key>$BUNDLE_ID</key><string>$MAS_PROFILE_NAME</string></dict>"
else
  SIGNING=(CODE_SIGN_STYLE=Automatic)
  PORTAL=(-allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"})
  EXPORT_SIGNING="<key>signingStyle</key><string>automatic</string>"
fi

echo "Dictate $MARKETING ($BUILD) for the Mac App Store, destination: $DESTINATION"

xcodegen generate
rm -rf "$OUT"
mkdir -p "$OUT"

xcodebuild archive \
  -project Dictate.xcodeproj -scheme Dictate -configuration AppStore \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath build \
  -onlyUsePackageVersionsFromResolvedFile \
  ${PORTAL[@]+"${PORTAL[@]}"} \
  ARCHS=arm64 \
  MARKETING_VERSION="$MARKETING" CURRENT_PROJECT_VERSION="$BUILD" \
  DEVELOPMENT_TEAM="$TEAM_ID" "${SIGNING[@]}"

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>app-store-connect</string>
  <key>destination</key>
  <string>$DESTINATION</string>
  <key>teamID</key>
  <string>$TEAM_ID</string>
  $EXPORT_SIGNING
  <key>manageAppVersionAndBuildNumber</key>
  <false/>
  <key>uploadSymbols</key>
  <true/>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT" \
  ${PORTAL[@]+"${PORTAL[@]}"}

if [ "$DESTINATION" = upload ]; then
  echo "Uploaded: the build appears in App Store Connect once processed."
else
  ls -la "$OUT"/*.pkg
fi
