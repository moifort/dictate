#!/bin/bash
# Renders docs/assets/og/og.html into site/og.png, the 1200×630 share preview.
set -euo pipefail

cd "$(dirname "$0")/.."
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

"$chrome" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --window-size=1200,630 --screenshot="$PWD/site/og.png" \
  "file://$PWD/docs/assets/og/og.html" 2>/dev/null

echo "site/og.png rendered"
