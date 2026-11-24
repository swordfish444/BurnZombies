#!/bin/bash
# Packages a signed BurnZombies.app into a styled, Retina-background macOS DMG
# with drag-to-/Applications layout. Signs the DMG when a Developer ID identity is supplied.
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:-dist/BurnZombies.app}"
output="${2:-dist/release/BurnZombies-macOS-universal.dmg}"
volume_name="BurnZombies"
signer="${BURNZOMBIES_SIGNING_IDENTITY:-}"

[[ -d "$app" ]] || { echo "FAIL: Missing app bundle at $app" >&2; exit 1; }
mkdir -p "$(dirname "$output")"
rm -f "$output"

if [[ ! -f packaging/artwork/dmg-background@2x.png ]]; then
  swift scripts/generate-artwork.swift
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/burnzombies-dmg.XXXXXX")"
mount_point="$work/mnt"
rw_dmg="$work/rw.dmg"
stage="$work/stage"
trap 'hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true; rm -rf "$work"' EXIT

mkdir -p "$stage/.background" "$mount_point"
ditto "$app" "$stage/BurnZombies.app"
ln -s /Applications "$stage/Applications"
cp packaging/artwork/dmg-background@2x.png "$stage/.background/background.png"

# Size image generously for Finder metadata + APFS/HFS+ overhead.
app_kb="$(du -sk "$stage" | awk '{print $1}')"
dmg_mb="$(( (app_kb / 1024) + 32 ))"

hdiutil create -srcfolder "$stage" -volname "$volume_name" -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" -format UDRW -size "${dmg_mb}m" "$rw_dmg" >/dev/null

hdiutil attach -readwrite -noverify -noautoopen -mountpoint "$mount_point" "$rw_dmg" >/dev/null

# Style Finder window silently when a GUI session is available (non-fatal on headless sessions).
if [[ -z "${BURNZOMBIES_SKIP_DMG_FINDER:-}" ]]; then
  osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "Finder"
  tell disk "$volume_name"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {160, 120, 820, 520}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set background picture of viewOptions to file ".background:background.png"
    set position of item "BurnZombies.app" of container window to {180, 205}
    set position of item "Applications" of container window to {480, 205}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
fi

# Hide background directory cleanly and detach.
SetFile -a V "$mount_point/.background" >/dev/null 2>&1 || true
sync
hdiutil detach "$mount_point" >/dev/null

# Convert to compressed read-only UDZO image.
hdiutil convert "$rw_dmg" -format UDZO -imagekey zlib-level=9 -o "$output" >/dev/null

if [[ -n "$signer" && "$signer" != "-" ]]; then
  codesign --force --timestamp --sign "$signer" "$output"
  codesign --verify --verbose=2 "$output"
fi

echo "Built DMG: $output ($(du -h "$output" | awk '{print $1}'))"
