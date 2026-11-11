#!/bin/bash
set -euo pipefail

# Public installer: no sudo, package manager, compiler, or shell-profile changes.
version="0.19.0"
release_certificate="F6EE40DDEBB01F056DE8FC7910091F4FAC3D7B49"
client="auto"
launch=true
look_only=false
setup_options=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mcp) client="${2:?Choose auto, all, codex, claude, cursor, copilot, gemini or none}"; shift 2 ;;
    --no-open) launch=false; shift ;;
    --observe-only) setup_options+=(--observe-only); shift ;;
    --look-only) look_only=true; setup_options+=(--look-only); shift ;;
    --help) echo 'Install BurnZombies: install.sh [--mcp auto|codex|claude|none] [--observe-only] [--look-only] [--no-open]'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
case "$client" in auto|all|codex|claude|cursor|copilot|gemini|none) ;; *) echo 'Unknown MCP client.' >&2; exit 1 ;; esac
[[ "$(uname -s)" == Darwin ]] || { echo 'BurnZombies needs macOS 14 or later.' >&2; exit 1; }
os_major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$os_major" -ge 14 ]] || { echo 'BurnZombies needs macOS 14 or later.' >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/burnzombies-install.XXXXXX")"
replacing=false
finish_install() {
  status=$?
  if [[ "$status" -ne 0 ]]; then
    if [[ "$replacing" == true && -x "$app/Contents/MacOS/burnzombies" ]]; then
      if ! "$app/Contents/MacOS/burnzombies" stop-observer "$app"; then
        echo "Rollback paused: the observer is still closing. Preserve $app and $work/previous.app" >&2
        return
      fi
    fi
    if [[ "$replacing" == true ]]; then rm -rf "$app"; fi
    if [[ -d "$work/previous.app" ]]; then
      if [[ -e "$app" || -L "$app" ]]; then
        echo "Rollback preserved both locations without merging: $app and $work/previous.app" >&2
        return
      fi
      if ! mv "$work/previous.app" "$app"; then
        echo "Rollback could not finish. Previous app preserved at $work/previous.app" >&2
        return
      fi
      if $launch; then "$app/Contents/MacOS/burnzombies" start-observer || true; fi
      echo 'Previous app restored.' >&2
    fi
  fi
  rm -rf "$work"
}
trap finish_install EXIT
asset="BurnZombies-macOS-universal.tar.gz"
base="https://github.com/swordfish444/BurnZombies/releases/download/v$version"
echo 'Downloading BurnZombies…'
curl --proto '=https' --tlsv1.2 -fsSL "$base/$asset" -o "$work/$asset"
curl --proto '=https' --tlsv1.2 -fsSL "$base/SHA256SUMS" -o "$work/SHA256SUMS"
expected="$(awk -v name="$asset" '$2 == name { print $1 }' "$work/SHA256SUMS")"
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { echo 'Release checksum is missing.' >&2; exit 1; }
actual="$(shasum -a 256 "$work/$asset" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || { echo 'Download checksum failed. Nothing installed.' >&2; exit 1; }
tar -tzf "$work/$asset" > "$work/entries"
if tar -tvzf "$work/$asset" | LC_ALL=C grep -E '^[^d-]' >/dev/null; then
  echo 'Unexpected archive links. Nothing installed.' >&2; exit 1
fi
if LC_ALL=C grep -Ev '^BurnZombies\.app(/[^[:cntrl:]]*)?/?$' "$work/entries" >/dev/null ||
  grep -E '(^|/)\.\.(/|$)' "$work/entries" >/dev/null; then
  echo 'Unexpected archive paths. Nothing installed.' >&2; exit 1
fi
tar -xzf "$work/$asset" -C "$work"
# A valid signature alone also accepts ad-hoc code. Apple's certificate requirement
# authenticates the release identity across every universal architecture, before code runs.
codesign --verify --deep --strict -R "=certificate leaf = H\"$release_certificate\"" "$work/BurnZombies.app"
identity="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$work/BurnZombies.app/Contents/Info.plist")"
[[ "$identity" == io.burnzombies.app ]] || { echo 'Unexpected app identity.' >&2; exit 1; }

destination="${BURNZOMBIES_INSTALL_DIR:-$HOME/Applications}"
mkdir -p "$destination"
app="$destination/BurnZombies.app"
if [[ -e "$app" || -L "$app" ]]; then
  [[ ! -L "$app" ]] || { echo 'Refusing to replace an app symlink.' >&2; exit 1; }
  existing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
  [[ "$existing" == io.burnzombies.app ]] || { echo 'An unrelated app already occupies the install path.' >&2; exit 1; }
  # Finish the old observer before moving its running executable or database owner.
  "$work/BurnZombies.app/Contents/MacOS/burnzombies" stop-observer "$app"
  if ! mv "$app" "$work/previous.app"; then
    if $launch; then "$app/Contents/MacOS/burnzombies" start-observer || true; fi
    echo 'Previous app could not be moved; update cancelled.' >&2
    exit 1
  fi
fi
# Hold every burn before the new app is in place: an agent's BurnZombies tools can start it
# before setup below has finished.
if $look_only && ! "$work/BurnZombies.app/Contents/MacOS/burnzombies" autopilot look-only >/dev/null; then
  echo 'Look-only setup failed. Nothing installed.' >&2; exit 1
fi
replacing=true
if ! ditto "$work/BurnZombies.app" "$app"; then
  echo 'Install failed; rolling back.' >&2; exit 1
fi

if [[ "$client" != none ]]; then
  if ! "$app/Contents/MacOS/burnzombies" retire-skill --check ||
     ! "$app/Contents/MacOS/burnzombies" setup --harness "$client" ${setup_options[@]+"${setup_options[@]}"} ||
     ! "$app/Contents/MacOS/burnzombies" retire-skill; then
    echo 'Harness configuration failed; rolling back. Configurations were preserved.' >&2
    exit 1
  fi
elif $look_only && ! "$app/Contents/MacOS/burnzombies" autopilot look-only; then
  echo 'Look-only setup failed; rolling back.' >&2
  exit 1
fi
if $launch; then
  "$app/Contents/MacOS/burnzombies" start-observer
  echo "BurnZombies $version is running in your menu bar: look for the skull."
  if $look_only; then
    echo "Within a minute it shows what it found and asks you about the rest."
  else
    echo "Within a minute it shows what it found, burns what's clearly safe and asks you about the rest."
  fi
else
  echo "BurnZombies $version is installed at $app. Open it to start."
fi
echo "Old project copies are backed up before they go, so you can restore them; junk folders rebuild themselves."
echo "Optional: Full Disk Access also covers Desktop, Documents and Downloads. Use Allow Full Disk Access in the menu."
