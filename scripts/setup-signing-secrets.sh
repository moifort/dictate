#!/usr/bin/env bash
# Stores the Developer ID and notarization secrets the release workflow needs.
#
# Extracts "Developer ID Application" from the login keychain into a .p12
# protected by a random password, so nothing has to be exported by hand: macOS
# only asks to allow the export of the keychain's private keys.
#
#   scripts/setup-signing-secrets.sh
set -euo pipefail

ASC_KEY_ID="M7447599QX"
ASC_ISSUER_ID="58ccb3ea-10df-4d1e-ae5c-02fba75ab425"
ASC_KEY_P8="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
IDENTITY="Developer ID Application"

cd "$(dirname "$0")/.."

gh auth status >/dev/null 2>&1 || { echo "Run 'gh auth login' first." >&2; exit 1; }
[ -f "$ASC_KEY_P8" ] || { echo "Missing $ASC_KEY_P8" >&2; exit 1; }
security find-identity -v -p codesigning "$LOGIN_KEYCHAIN" | grep -q "$IDENTITY" \
  || { echo "No \"$IDENTITY\" identity in the login keychain." >&2; exit 1; }

WORK="$(mktemp -d)"
KEYCHAIN="$WORK/extract.keychain-db"
cleanup() {
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

P12_PASSWORD="$(uuidgen)"
KEYCHAIN_PASSWORD="$(uuidgen)"

# `security export` cannot pick one identity: export them all, keep only the
# Developer ID one in a scratch keychain, and export that keychain.
echo "macOS will ask to allow exporting each private key of the login keychain."
security export -k "$LOGIN_KEYCHAIN" -t identities -f pkcs12 \
  -P "$P12_PASSWORD" -o "$WORK/all.p12"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/all.p12" -P "$P12_PASSWORD" -f pkcs12 -A -k "$KEYCHAIN" >/dev/null

security find-identity "$KEYCHAIN" | grep -E '^ +[0-9]+\) ' | grep -v "\"$IDENTITY" \
  | awk '{print $2}' | sort -u | while read -r HASH; do
    security delete-identity -Z "$HASH" "$KEYCHAIN" >/dev/null
  done

COUNT=$(security find-identity -v -p codesigning "$KEYCHAIN" | grep -c "$IDENTITY" || true)
[ "$COUNT" = "1" ] || { echo "Expected one \"$IDENTITY\" identity, found $COUNT." >&2; exit 1; }
security find-identity -v -p codesigning "$KEYCHAIN"

security export -k "$KEYCHAIN" -t identities -f pkcs12 \
  -P "$P12_PASSWORD" -o "$WORK/developer-id.p12"

base64 -i "$WORK/developer-id.p12" | gh secret set DEVELOPER_ID_P12
printf '%s' "$P12_PASSWORD" | gh secret set DEVELOPER_ID_P12_PASSWORD
gh secret set ASC_KEY_ID --body "$ASC_KEY_ID"
gh secret set ASC_KEY_P8 < "$ASC_KEY_P8"
gh secret set ASC_ISSUER_ID --body "$ASC_ISSUER_ID"

echo "Secrets stored:"
gh secret list
