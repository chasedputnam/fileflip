#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

die() {
  printf 'create-release-dmg.sh: %s\n' "$*" >&2
  exit 1
}

for tool in ditto hdiutil osascript python3 swift; do
  command -v "$tool" >/dev/null || die "missing required tool: $tool"
done

PROJECT_DIR=$(cd ../ && pwd)
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$PROJECT_DIR/release-artifacts/"
APP="$WORK/FileFlip.app"
OUTPUT="$WORK/FileFlip.dmg"
STAGING="$WORK/root"
BACKGROUND_DIR="$STAGING/.background"
BACKGROUND="$BACKGROUND_DIR/background.png"
READ_WRITE_DMG="$WORK/FileFlip-rw.dmg"
ATTACH_PLIST="$WORK/attach.plist"
MOUNT=""
DEVICE=""
VOLUME_NAME="FileFlip"
MOUNTED=0
[[ ! -e "/Volumes/$VOLUME_NAME" ]] || die "eject the existing $VOLUME_NAME volume before creating the disk image"

cleanup() {
  if [[ "$MOUNTED" -eq 1 ]]; then
    hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true
  fi
  rm -rf $STAGING
  rm -f $ATTACH_PLIST
  rm -f $READ_WRITE_DMG
}
trap cleanup EXIT

mkdir -p "$STAGING" "$BACKGROUND_DIR"
ditto "$APP" "$STAGING/FileFlip.app"
ln -s /Applications "$STAGING/Applications"
touch "$STAGING/.metadata_never_index"
"$ROOT/scripts/render-dmg-background.swift" "$BACKGROUND"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -format UDRW \
  -ov \
  "$READ_WRITE_DMG" >/dev/null

hdiutil attach \
  -readwrite \
  -noverify \
  -noautoopen \
  -plist \
  "$READ_WRITE_DMG" > "$ATTACH_PLIST"
MOUNT="$(python3 -c 'import plistlib, sys; entities=plistlib.load(open(sys.argv[1], "rb"))["system-entities"]; print(next(entity["mount-point"] for entity in entities if "mount-point" in entity))' "$ATTACH_PLIST")"
DEVICE="$(python3 -c 'import plistlib, sys; entities=plistlib.load(open(sys.argv[1], "rb"))["system-entities"]; print(next(entity["dev-entry"] for entity in entities if "mount-point" in entity))' "$ATTACH_PLIST")"
[[ -d "$MOUNT" && -n "$DEVICE" ]] || die "unable to identify mounted disk image"
MOUNTED=1

osascript - "$VOLUME_NAME" <<'APPLESCRIPT'
on run arguments
  set volumeName to item 1 of arguments
  tell application "Finder"
    tell disk volumeName
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set pathbar visible of container window to false
      set bounds of container window to {100, 100, 760, 520}
      set theIconViewOptions to icon view options of container window
      set arrangement of theIconViewOptions to not arranged
      set icon size of theIconViewOptions to 112
      set text size of theIconViewOptions to 13
      set background picture of theIconViewOptions to file ".background:background.png"
      set position of item "FileFlip.app" of container window to {166, 226}
      set position of item "Applications" of container window to {494, 226}
      close
      open
      update without registering applications
      delay 3
      close
    end tell
  end tell
end run
APPLESCRIPT
for _ in {1..10}; do
  [[ -f "$MOUNT/.DS_Store" ]] && break
  sleep 1
done
[[ -f "$MOUNT/.DS_Store" ]] || die "Finder did not persist the disk image layout"

sync
hdiutil detach "$DEVICE" >/dev/null
MOUNTED=0
hdiutil convert "$READ_WRITE_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT" >/dev/null
[[ -s "$OUTPUT" ]] || die "DMG creation produced no output"
printf 'Created styled disk image: %s\n' "$OUTPUT"
