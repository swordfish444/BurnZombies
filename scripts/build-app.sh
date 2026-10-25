#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
universal=false
if [[ "${1:-}" == "--universal" ]]; then universal=true; fi
if $universal; then
  for arch in arm64 x86_64; do
    # SwiftBuild can reuse Products/Release for different triples. Separate roots
    # keep the second architecture from replacing the first before lipo runs.
    swift build -c release --scratch-path ".build/universal-$arch" --triple "$arch-apple-macosx14.0"
  done
  built="$(swift build -c release --scratch-path .build/universal-arm64 --triple arm64-apple-macosx14.0 --show-bin-path)"
  intel="$(swift build -c release --scratch-path .build/universal-x86_64 --triple x86_64-apple-macosx14.0 --show-bin-path)"
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
mkdir -p "$bundle/Contents/Resources/burnzombies"
cp skills/burnzombies/SKILL.md "$bundle/Contents/Resources/burnzombies/SKILL.md"
mkdir -p "$bundle/Contents/Resources/ThirdPartyNotices"
for dependency in swift-sdk swift-system swift-log eventsource; do
  for license in .build/checkouts/"$dependency"/LICENSE*; do
    [[ -f "$license" ]] || continue
    cp -f "$license" "$bundle/Contents/Resources/ThirdPartyNotices/$dependency-$(basename "$license")"
  done
done
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.burnzombies.app</string>
<key>CFBundleName</key><string>BurnZombies</string>
<key>CFBundleExecutable</key><string>BurnZombiesApp</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$bundle/Contents/MacOS/burnzombies"
codesign --force --sign - "$bundle/Contents/MacOS/burnzombies-mcp"
codesign --force --sign - "$bundle"
echo "Built $bundle (local ad-hoc signature; not notarized)."
