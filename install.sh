#!/bin/bash
set -euo pipefail

# Public installer: no sudo, package manager, compiler, or shell-profile changes.
version="0.7.1"
client="auto"
launch=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mcp) client="${2:?Choose auto, all, codex, claude, cursor, copilot, gemini or none}"; shift 2 ;;
    --no-open) launch=false; shift ;;
    --help) echo 'Install BurnZombies: install.sh [--mcp auto|all|codex|claude|cursor|copilot|gemini|none] [--no-open]'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
case "$client" in auto|all|codex|claude|cursor|copilot|gemini|none) ;; *) echo 'Unknown MCP client.' >&2; exit 1 ;; esac
[[ "$(uname -s)" == Darwin ]] || { echo 'BurnZombies needs macOS 14 or later.' >&2; exit 1; }
os_major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$os_major" -ge 14 ]] || { echo 'BurnZombies needs macOS 14 or later.' >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/burnzombies-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT
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
codesign --verify --deep --strict "$work/BurnZombies.app"
identity="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$work/BurnZombies.app/Contents/Info.plist")"
[[ "$identity" == io.burnzombies.app ]] || { echo 'Unexpected app identity.' >&2; exit 1; }

destination="${BURNZOMBIES_INSTALL_DIR:-$HOME/Applications}"
mkdir -p "$destination"
app="$destination/BurnZombies.app"
if [[ -e "$app" || -L "$app" ]]; then
  [[ ! -L "$app" ]] || { echo 'Refusing to replace an app symlink.' >&2; exit 1; }
  existing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
  [[ "$existing" == io.burnzombies.app ]] || { echo 'An unrelated app already occupies the install path.' >&2; exit 1; }
  mv "$app" "$work/previous.app"
fi
if ! ditto "$work/BurnZombies.app" "$app"; then
  rm -rf "$app"
  [[ ! -d "$work/previous.app" ]] || mv "$work/previous.app" "$app"
  echo 'Install failed; previous app restored.' >&2; exit 1
fi

if [[ "$client" != none ]]; then
  if ! "$app/Contents/MacOS/burnzombies" install-skill --check ||
     ! "$app/Contents/MacOS/burnzombies" setup --harness "$client" ||
     ! "$app/Contents/MacOS/burnzombies" install-skill; then
    rm -rf "$app"
    [[ ! -d "$work/previous.app" ]] || mv "$work/previous.app" "$app"
    echo 'Harness configuration failed; previous app restored. Configurations were preserved.' >&2
    exit 1
  fi
fi
if $launch; then "$app/Contents/MacOS/burnzombies" start-observer; fi
echo "Installed BurnZombies $version. Your work can keep running."
