#!/bin/bash
# Builds the Dictate disk image: the app, an Applications alias, and a Finder
# window laid out so the install is a single drag.
#
#   scripts/build-dmg.sh <path/to/Dictate.app> <output.dmg>
#
# A read-write image is mounted first so Finder can be scripted into saving
# the window size, background and icon positions in the volume's .DS_Store;
# it is then converted into the compressed, read-only image that ships.
# Signing and notarization are the caller's job.
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <Dictate.app> <output.dmg>" >&2
  exit 64
fi
APP="$1"
DMG="$2"
VOLUME="Dictate"
HERE="$(cd "$(dirname "$0")" && pwd)"

# Window geometry, in points. The icon positions match the arrow painted by
# render-background.swift: change both together.
WINDOW_LEFT=200
WINDOW_TOP=140
WINDOW_WIDTH=660
WINDOW_HEIGHT=400
TITLE_BAR=28   # Finder's window bounds include it; the picture does not
ICON_SIZE=128
APP_X=165
APPLICATIONS_X=495
ICONS_Y=175

WORK="$(mktemp -d -t dictate-dmg)"
STAGING="$WORK/staging"
RW_IMAGE="$WORK/rw.dmg"
MOUNT_POINT="$WORK/mount"
cleanup() {
  diskutil unmount force "$MOUNT_POINT" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "Staging $VOLUME"
mkdir -p "$STAGING/.background"
ditto "$APP" "$STAGING/Dictate.app"
ln -s /Applications "$STAGING/Applications"
swift "$HERE/dmg/render-background.swift" "$STAGING/.background/background.png"
# The app's own icon stands for the mounted volume on the desktop.
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGING/.VolumeIcon.icns"

echo "Creating a read-write image"
mkdir -p "$MOUNT_POINT"
hdiutil create -quiet -srcfolder "$STAGING" -volname "$VOLUME" \
  -fs HFS+ -format UDRW "$RW_IMAGE"
hdiutil attach -quiet -readwrite -noverify -noautoopen \
  -mountpoint "$MOUNT_POINT" "$RW_IMAGE"
SetFile -a C "$MOUNT_POINT"
SetFile -a V "$MOUNT_POINT/.VolumeIcon.icns" "$MOUNT_POINT/.background"

echo "Laying out the Finder window"
# Finder only writes a .DS_Store for a window it has opened, hence the
# open/close dance. The mount point is given as a POSIX path rather than a
# volume name so that a stale /Volumes/Dictate from an earlier run cannot be
# picked up instead.
osascript - "$MOUNT_POINT" <<APPLESCRIPT
on run argv
  set mountPoint to POSIX file (item 1 of argv) as alias
  tell application "Finder"
    open mountPoint
    set theWindow to container window of mountPoint
    set current view of theWindow to icon view
    set toolbar visible of theWindow to false
    set statusbar visible of theWindow to false
    set pathbar visible of theWindow to false
    set sidebar width of theWindow to 0
    set bounds of theWindow to {$WINDOW_LEFT, $WINDOW_TOP, $((WINDOW_LEFT + WINDOW_WIDTH)), $((WINDOW_TOP + TITLE_BAR + WINDOW_HEIGHT))}
    set viewOptions to icon view options of theWindow
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to $ICON_SIZE
    set text size of viewOptions to 13
    set label position of viewOptions to bottom
    set shows item info of viewOptions to false
    set shows icon preview of viewOptions to true
    set background picture of viewOptions to file ".background:background.png" of mountPoint
    set position of item "Dictate.app" of mountPoint to {$APP_X, $ICONS_Y}
    set position of item "Applications" of mountPoint to {$APPLICATIONS_X, $ICONS_Y}
    close theWindow
    -- Reopen once so Finder writes the final layout, then close for good.
    open mountPoint
    delay 1
    close container window of mountPoint
  end tell
end run
APPLESCRIPT

# Give Finder a moment to flush .DS_Store, then drop what it should not keep.
sync
sleep 2
rm -rf "$MOUNT_POINT/.fseventsd" "$MOUNT_POINT/.Trashes"
hdiutil detach -quiet "$MOUNT_POINT"

echo "Compressing to $DMG"
rm -f "$DMG"
hdiutil convert -quiet -format ULFO -o "$DMG" "$RW_IMAGE"
hdiutil verify -quiet "$DMG"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
