#!/bin/bash
# The Mac App Store build: archives the sandboxed AppStore configuration,
# signs it for distribution and either uploads it to App Store Connect or
# leaves the installer package in build/app-store.
#
#   scripts/build-app-store.sh            # archive, export the .pkg, stop
#   scripts/build-app-store.sh --upload   # archive and upload to App Store Connect
#
# Signing is automatic: Xcode creates or downloads the Apple Distribution and
# Mac Installer Distribution certificates and the provisioning profile. It
# authenticates with an App Store Connect API key when these are set:
#
#   ASC_KEY_ID=…  ASC_ISSUER_ID=…  ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_….p8
#
# and otherwise with the Apple account signed in to Xcode.
#
# Version and build number follow the Developer ID release: the latest tag and
# the commit count, so each upload carries a higher build number.
set -euo pipefail

cd "$(dirname "$0")/.."

DESTINATION=export
[ "${1:-}" = "--upload" ] && DESTINATION=upload

TEAM_ID=46C337T7YN
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
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} \
  ARCHS=arm64 \
  MARKETING_VERSION="$MARKETING" CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM_ID"

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
  <key>signingStyle</key>
  <string>automatic</string>
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
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"}

if [ "$DESTINATION" = upload ]; then
  echo "Uploaded: the build appears in App Store Connect → TestFlight once processed."
else
  ls -la "$OUT"/*.pkg
fi
