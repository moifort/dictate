#!/bin/bash
# The Release build of the app, unsigned: the release workflow signs it by
# hand afterwards. The Tests workflow runs it too on main, so the compiled
# packages of the Release configuration stay cached for the next tag.
#
#   MARKETING=0.9.2 BUILD=412 scripts/ci-build-release.sh
set -euo pipefail

xcodebuild build \
  -project Dictate.xcodeproj -scheme Dictate -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build \
  -onlyUsePackageVersionsFromResolvedFile \
  ARCHS=arm64 \
  MARKETING_VERSION="${MARKETING:-0.0.0}" CURRENT_PROJECT_VERSION="${BUILD:-1}" \
  CODE_SIGNING_ALLOWED=NO
