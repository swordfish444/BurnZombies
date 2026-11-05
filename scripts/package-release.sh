#!/bin/bash
# Builds a release's downloads on the maintainer's Mac, from a clean commit: the universal app,
# its install archive, the MCPB bundle, server.json and SHA256SUMS, all in dist/release. It
# publishes nothing. Every release since v0.13.0 is signed with the same certificate, and macOS
# ties Full Disk Access to it, so a build signed any other way stops here.
set -euo pipefail
cd "$(dirname "$0")/.."
expected="${BURNZOMBIES_RELEASE_CERT_SHA256:-dbe8297fd599efa4bb942d0ebb5487e3bc27c15d7b71fadc8253da8ab1d697b9}"
release=dist/release
[[ -z "$(git status --porcelain)" ]] || { echo 'Commit first: a release is built from a commit.' >&2; exit 1; }
[[ ! -e "$release" ]] || { echo "Move $release aside first." >&2; exit 1; }

scripts/build-app.sh --universal
app=dist/BurnZombies.app
codesign --verify --deep --strict "$app"
certs="$(mktemp -d)"
trap 'rm -rf "$certs"' EXIT
codesign -d --extract-certificates="$certs/cert" "$app" 2>/dev/null || true
actual="$( [[ -f "$certs/cert0" ]] && shasum -a 256 "$certs/cert0" | awk '{print $1}' || echo 'no certificate (ad-hoc)')"
if [[ "$actual" != "$expected" ]]; then
  echo "Signed with $actual, not the release certificate. Load it with scripts/release-identity.sh load (see AGENTS.md), then build again." >&2
  exit 1
fi

python3 scripts/package-mcpb.py --output "$release"
rm "$release/MCPB-SHA256SUMS"
COPYFILE_DISABLE=1 tar -czf "$release/BurnZombies-macOS-universal.tar.gz" -C dist BurnZombies.app
(cd "$release" && shasum -a 256 BurnZombies-macOS-universal.tar.gz BurnZombies-macOS-universal.mcpb > SHA256SUMS)
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
echo "BurnZombies $version from $(git rev-parse --short HEAD), signed with the release certificate:"
ls -1 "$release"
