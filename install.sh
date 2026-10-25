#!/bin/bash
set -euo pipefail

# Public installer: no sudo, package manager, compiler, or shell-profile changes.
version="0.2.0"
client="auto"
launch=true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mcp) client="${2:?Choose auto, codex, claude, or none}"; shift 2 ;;
    --no-open) launch=false; shift ;;
    --help) echo 'Install BurnZombies: install.sh [--mcp auto|codex|claude|none] [--no-open]'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done
case "$client" in auto|codex|claude|none) ;; *) echo 'Unknown MCP client.' >&2; exit 1 ;; esac
[[ "$(uname -s)" == Darwin ]] || { echo 'BurnZombies needs macOS 14 or later.' >&2; exit 1; }
os_major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$os_major" -ge 14 ]] || { echo 'BurnZombies needs macOS 14 or later.' >&2; exit 1; }
if [[ "$client" == auto ]]; then
  if command -v codex >/dev/null 2>&1; then client=codex
  elif command -v claude >/dev/null 2>&1; then client=claude
  else client=none; fi
fi
if [[ "$client" != none ]] && ! command -v "$client" >/dev/null 2>&1; then
  echo "$client was not found. Install it first, or use --mcp none for the Mac app." >&2; exit 1
fi

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

server="$app/Contents/MacOS/burnzombies-mcp"
if $launch; then open "$app"; fi
case "$client" in
  codex|claude)
    if "$client" mcp get burnzombies > "$work/existing-mcp" 2>/dev/null; then
      echo 'Existing burnzombies MCP settings preserved. Check its command if your install location changed.'
    elif [[ "$client" == codex ]]; then
      codex mcp add burnzombies -- "$server"
    else
      claude mcp add --scope user --transport stdio burnzombies -- "$server"
    fi ;;
esac
echo "Installed BurnZombies $version."
if [[ "$client" != none ]]; then
  echo "MCP connected to $client. Start a new agent session and ask: Tame the horde with BurnZombies."
else
  echo "MCP command: $server"
fi
