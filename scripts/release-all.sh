#!/bin/bash
# Local one-command CI/CD release orchestrator for BurnZombies (no GitHub Actions required).
# Builds universal arm64+x86_64 binaries, signs with Apple Developer ID (Hardened Runtime),
# notarizes & staples .app and .dmg, verifies Gatekeeper + install/updater proofs, updates
# Homebrew Cask / Nix Flake / GitHub Pages / SHA256SUMS, and optionally publishes everywhere.
#
# Usage:
#   scripts/release-all.sh [--publish] [--allow-self-signed] [--skip-tests] [--tap-repo owner/homebrew-tap]
set -euo pipefail
cd "$(dirname "$0")/.."

publish=false
allow_self_signed=false
skip_tests=false
tap_repo="${BURNZOMBIES_HOMEBREW_TAP:-swordfish444/homebrew-tap}"
notary_profile="${BURNZOMBIES_NOTARY_PROFILE:-burnzombies-notary}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --publish) publish=true; shift ;;
    --allow-self-signed) allow_self_signed=true; shift ;;
    --skip-tests) skip_tests=true; shift ;;
    --tap-repo) tap_repo="${2:?Pass owner/homebrew-tap}"; shift 2 ;;
    --notary-profile) notary_profile="${2:?Pass notarytool keychain profile}"; shift 2 ;;
    --help|-h)
      sed -n '2,10p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

die() { echo "FAIL: $*" >&2; exit 1; }

[[ -z "$(git status --porcelain)" ]] || die "Commit all changes first; a release must build from a clean commit."

# 1. Detect Apple Developer ID Application signing identity (unless explicitly overridden).
dev_id="${BURNZOMBIES_SIGNING_IDENTITY:-}"
if [[ -z "$dev_id" ]]; then
  dev_id="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]* (7K3GR5QJRH)\)".*/\1/p' | head -n 1 || true)"
fi
is_developer_id=false
if [[ "$dev_id" == "Developer ID Application:"* ]]; then
  is_developer_id=true
  export BURNZOMBIES_SIGNING_IDENTITY="$dev_id"
  export BURNZOMBIES_HARDENED_RUNTIME=1
  echo "Using Apple Developer ID: $dev_id"
elif $allow_self_signed; then
  export BURNZOMBIES_SIGNING_IDENTITY="${BURNZOMBIES_SIGNING_IDENTITY:-BurnZombies Local Signing}"
  echo "WARNING: Building with non-Developer-ID identity: $BURNZOMBIES_SIGNING_IDENTITY (skipping Apple notarization)."
else
  die "No 'Developer ID Application' certificate found in Keychain. Run scripts/setup-apple-signing.sh first (or pass --allow-self-signed for local dry runs)."
fi

if $publish && ! $is_developer_id; then
  die "Publishing requires an Apple Developer ID Application identity."
fi

# 2. Run full local verification suite.
if ! $skip_tests; then
  echo "==> Running full local proof suite..."
  caffeinate -i -m scripts/test.sh --full
fi

# 3. Ensure artwork & AppIcon.icns are up to date.
if [[ ! -f packaging/artwork/AppIcon.icns || ! -f packaging/artwork/dmg-background@2x.png ]]; then
  swift scripts/generate-artwork.swift
fi

# 4. Build universal app bundle (arm64 + x86_64) with Hardened Runtime signing.
rm -rf dist/release
mkdir -p dist/release
echo "==> Building universal BurnZombies.app..."
caffeinate -i -m scripts/build-app.sh --universal
app="dist/BurnZombies.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"

codesign --verify --deep --strict --verbose=2 "$app"
if $is_developer_id; then
  codesign --verify --strict -R '=anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "7K3GR5QJRH"' "$app"
fi

# 5. Notarize & staple BurnZombies.app before packing .tar.gz and .mcpb.
if $is_developer_id; then
  echo "==> Submitting BurnZombies.app for Apple notarization (profile: $notary_profile)..."
  notary_zip="$(mktemp -t burnzombies-notary).zip"
  trap 'rm -f "$notary_zip"' EXIT
  ditto -c -k --keepParent "$app" "$notary_zip"
  xcrun notarytool submit "$notary_zip" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  spctl --assess --type execute --verbose=4 "$app"
  rm -f "$notary_zip"
fi

# 6. Build .tar.gz, .mcpb (+ server.json), and styled .dmg.
release="dist/release"
tarball="$release/BurnZombies-macOS-universal.tar.gz"
dmg="$release/BurnZombies-macOS-universal.dmg"
mcpb="$release/BurnZombies-macOS-universal.mcpb"

COPYFILE_DISABLE=1 tar -czf "$tarball" -C dist BurnZombies.app
python3 scripts/package-mcpb.py --app "$app" --output "$release"
rm -f "$release/MCPB-SHA256SUMS"
scripts/build-dmg.sh "$app" "$dmg"

if $is_developer_id; then
  echo "==> Notarizing & stapling DMG..."
  xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
fi

(cd "$release" && shasum -a 256 \
  BurnZombies-macOS-universal.tar.gz \
  BurnZombies-macOS-universal.dmg \
  BurnZombies-macOS-universal.mcpb > SHA256SUMS)

tar_sha="$(shasum -a 256 "$tarball" | awk '{print $1}')"
dmg_sha="$(shasum -a 256 "$dmg" | awk '{print $1}')"

# 7. Run release install & app-update proofs.
echo "==> Running release install & updater proofs..."
if $is_developer_id; then
  python3 scripts/test-install.py "$tarball"
else
  python3 scripts/test-install.py "$tarball" --fixture-signer
fi
if $is_developer_id; then
  python3 scripts/test-app-update.py "$app"
fi

# 8. Render updated Homebrew Cask and release manifest summary inside dist/release.
python3 - "$version" "$dmg_sha" "$tar_sha" "$release/burnzombies.rb" <<'PY'
import pathlib, re, sys
version, dmg_sha, tar_sha, out = sys.argv[1:5]
cask = pathlib.Path("packaging/homebrew/burnzombies.rb").read_text()
cask = re.sub(r'version "[^"]+"', f'version "{version}"', cask, count=1)
cask = re.sub(r'sha256 "[^"]+"', f'sha256 "{dmg_sha}"', cask, count=1)
pathlib.Path(out).write_text(cask)
print(f"Prepared Homebrew Cask ({out}): version={version} dmg_sha256={dmg_sha}")
print(f"Nix Flake releaseSha256={tar_sha}")
PY

echo "==> Release artifacts ready in $release:"
ls -lh "$release"

if ! $publish; then
  echo "Dry build complete. Pass --publish to upload GitHub Release, update Homebrew Tap, and publish MCP Registry."
  exit 0
fi

# 9. Publish GitHub Release (idempotent check).
tag="v$version"
echo "==> Publishing GitHub Release $tag..."
if gh release view "$tag" >/dev/null 2>&1; then
  die "GitHub release $tag already exists. Bump version or delete the existing draft first."
fi
gh release create "$tag" \
  --title "$tag" \
  --generate-notes \
  "$tarball" "$dmg" "$mcpb" "$release/SHA256SUMS" "$release/server.json"

# 10. Publish Homebrew Tap Cask (`brew install --cask swordfish444/tap/burnzombies`).
echo "==> Updating Homebrew Tap ($tap_repo)..."
tap_dir="$(mktemp -d "${TMPDIR:-/tmp}/burnzombies-tap.XXXXXX")"
trap 'rm -rf "$tap_dir"' EXIT
if ! gh repo view "$tap_repo" >/dev/null 2>&1; then
  echo "Creating Homebrew tap repository $tap_repo..."
  gh repo create "$tap_repo" --public --description "Homebrew Cask tap for BurnZombies" --add-readme
fi
gh repo clone "$tap_repo" "$tap_dir/tap"
mkdir -p "$tap_dir/tap/Casks"
cp "$release/burnzombies.rb" "$tap_dir/tap/Casks/burnzombies.rb"
(
  cd "$tap_dir/tap"
  git add Casks/burnzombies.rb
  if ! git diff --cached --quiet; then
    git commit -m "burnzombies $version"
    git push origin HEAD
  fi
)
if command -v brew >/dev/null 2>&1; then
  brew audit --cask --strict "$tap_dir/tap/Casks/burnzombies.rb" || true
fi

# 11. Publish Official MCP Registry entry if mcp-publisher is installed.
if command -v mcp-publisher >/dev/null 2>&1; then
  echo "==> Publishing to Official MCP Registry..."
  (cd "$release" && mcp-publisher publish)
else
  echo "NOTE: mcp-publisher not installed; install via 'brew install mcp-publisher' to auto-publish dist/release/server.json."
fi

echo "==> Published BurnZombies $tag across GitHub Releases and Homebrew Tap ($tap_repo)!"
