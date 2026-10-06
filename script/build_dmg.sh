#!/usr/bin/env bash
# Wraps an app bundle in a drag-to-install DMG: a 660×400 Finder window with the background from
# assets/dmg (re-render it with script/render_dmg_background.swift), the app on the left, and an
# Applications link on the right. Finder lays the window out through AppleScript, so this needs a
# logged-in GUI session (local Macs and GitHub's macOS runners have one). Any failure stops the build.
#
# Usage: script/build_dmg.sh <App.app> <volume name> <output.dmg>
set -euo pipefail

APP_BUNDLE="$1"
VOLUME_NAME="$2"
DMG_PATH="$3"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_FILE="$(basename "$APP_BUNDLE")"

if [ -d "/Volumes/$VOLUME_NAME" ]; then
  echo "error: /Volumes/$VOLUME_NAME is already mounted; eject it first." >&2
  exit 1
fi

WORK="$(mktemp -d)"
MOUNT=""
cleanup() {
  if [ -n "$MOUNT" ] && [ -d "$MOUNT" ]; then hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
cp -R "$APP_BUNDLE" "$STAGE/$APP_FILE"
ln -s /Applications "$STAGE/Applications"
# One TIFF holding the 1x and 2x art, so Retina screens get the sharp one.
tiffutil -cathidpicheck "$ROOT/assets/dmg/background.png" "$ROOT/assets/dmg/background@2x.png" \
  -out "$STAGE/.background/background.tiff" >/dev/null 2>&1

RW_DMG="$WORK/rw.dmg"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW_DMG" >/dev/null
MOUNT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\// { print $NF; exit }')"
[ -d "$MOUNT" ] || { echo "error: could not mount $RW_DMG" >&2; exit 1; }

# Window bounds include the ~28pt title bar, so the content area is 660×400.
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "$APP_FILE" of container window to {165, 210}
    set position of item "Applications" of container window to {495, 210}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

# Finder writes .DS_Store asynchronously; wait for it so the layout is in the image.
for _ in $(seq 1 20); do
  [ -f "$MOUNT/.DS_Store" ] && break
  sleep 0.5
done
[ -f "$MOUNT/.DS_Store" ] || { echo "error: Finder did not save the DMG window layout" >&2; exit 1; }
rm -rf "$MOUNT/.fseventsd"
chmod -Rf go-w "$MOUNT" || true
sync
hdiutil detach "$MOUNT" >/dev/null
MOUNT=""

rm -f "$DMG_PATH"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
