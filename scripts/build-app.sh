#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
universal=false
debug=false
if [[ "${1:-}" == "--universal" ]]; then universal=true; fi
# Debug binaries in a real bundle, for installer checks only; never for a release.
if [[ "${1:-}" == "--debug" ]]; then debug=true; fi
if $universal; then
  for arch in arm64 x86_64; do
    # SwiftBuild can reuse Products/Release for different triples. Separate roots
    # keep the second architecture from replacing the first before lipo runs.
    swift build -c release --scratch-path ".build/universal-$arch" --triple "$arch-apple-macosx14.0"
  done
  built="$(swift build -c release --scratch-path .build/universal-arm64 --triple arm64-apple-macosx14.0 --show-bin-path)"
  intel="$(swift build -c release --scratch-path .build/universal-x86_64 --triple x86_64-apple-macosx14.0 --show-bin-path)"
elif $debug; then
  swift build
  built="$(swift build --show-bin-path)"
else
  swift build -c release
  built="$(swift build -c release --show-bin-path)"
fi
bundle="dist/BurnZombies.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
for executable in BurnZombiesApp burnzombies burnzombies-mcp; do
  if $universal; then
    lipo -create "$built/$executable" "$intel/$executable" -output "$bundle/Contents/MacOS/$executable"
  else
    cp "$built/$executable" "$bundle/Contents/MacOS/$executable"
  fi
done
cp -R "$built/BurnZombies_BurnApp.bundle" "$bundle/Contents/Resources/"
cp -R "$built/BurnZombies_BurnCore.bundle" "$bundle/Contents/Resources/"
mkdir -p "$bundle/Contents/Resources/burnzombies"
cp skills/burnzombies/SKILL.md "$bundle/Contents/Resources/burnzombies/SKILL.md"
mkdir -p "$bundle/Contents/Resources/ThirdPartyNotices"
for dependency in swift-sdk swift-system swift-log eventsource TOMLKit; do
  for license in .build/checkouts/"$dependency"/LICENSE*; do
    [[ -f "$license" ]] || continue
    cp -f "$license" "$bundle/Contents/Resources/ThirdPartyNotices/$dependency-$(basename "$license")"
  done
done
cp -f .build/checkouts/TOMLKit/tomlplusplus/LICENSE "$bundle/Contents/Resources/ThirdPartyNotices/tomlplusplus-LICENSE"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.burnzombies.app</string>
<key>CFBundleName</key><string>BurnZombies</string>
<key>CFBundleExecutable</key><string>BurnZombiesApp</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.13.0</string>
<key>CFBundleVersion</key><string>54</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# macOS keys privacy grants such as Full Disk Access to the signer. One stable identity keeps
# them across updates; an ad-hoc signature makes every build a new app that must be allowed again.
identity="${BURNZOMBIES_SIGNING_IDENTITY:-BurnZombies Local Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$identity\""; then
  signer="$identity"
  signature="signed by \"$identity\", so macOS keeps Full Disk Access across updates"
else
  signer="-"
  signature="local ad-hoc signature: macOS asks for Full Disk Access again after every update until you run scripts/ensure-signing-identity.sh once"
fi
codesign --force --sign "$signer" "$bundle/Contents/MacOS/burnzombies"
codesign --force --sign "$signer" "$bundle/Contents/MacOS/burnzombies-mcp"
codesign --force --sign "$signer" "$bundle"
echo "Built $bundle ($signature; not notarized)."
