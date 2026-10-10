#!/usr/bin/env bash
# Stores the Developer ID and notarization secrets the release workflow needs.
#
# Before running it, export "Developer ID Application: Thibaut Mottet" from
# Keychain Access as a .p12 (right-click → Export). The script asks for that
# .p12's password, then deletes the .p12.
#
#   scripts/setup-signing-secrets.sh [path/to/developer-id.p12]
set -euo pipefail

P12="${1:-$HOME/Desktop/developer-id.p12}"
ASC_KEY_ID="M7447599QX"
ASC_ISSUER_ID="58ccb3ea-10df-4d1e-ae5c-02fba75ab425"
ASC_KEY_P8="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"

cd "$(dirname "$0")/.."

gh auth status >/dev/null 2>&1 || { echo "Run 'gh auth login' first." >&2; exit 1; }
[ -f "$ASC_KEY_P8" ] || { echo "Missing $ASC_KEY_P8" >&2; exit 1; }

if [ ! -f "$P12" ]; then
  echo "No certificate at $P12."
  echo "Keychain Access → login → My Certificates → right-click"
  echo "\"Developer ID Application: Thibaut Mottet\" → Export → $P12"
  open -b com.apple.keychainaccess 2>/dev/null || true
  exit 1
fi

read -rsp "Password of the .p12: " P12_PASSWORD; echo
if ! openssl pkcs12 -in "$P12" -passin "pass:$P12_PASSWORD" -noout 2>/dev/null; then
  echo "Wrong password, or not a .p12 file." >&2
  exit 1
fi

base64 -i "$P12" | gh secret set DEVELOPER_ID_P12
printf '%s' "$P12_PASSWORD" | gh secret set DEVELOPER_ID_P12_PASSWORD
gh secret set ASC_KEY_ID --body "$ASC_KEY_ID"
gh secret set ASC_KEY_P8 < "$ASC_KEY_P8"
gh secret set ASC_ISSUER_ID --body "$ASC_ISSUER_ID"

rm -f "$P12"
echo "Secrets stored, $P12 deleted:"
gh secret list
