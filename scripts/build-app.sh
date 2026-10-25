#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
bundle="dist/BurnZombies.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp .build/release/BurnZombiesApp "$bundle/Contents/MacOS/BurnZombiesApp"
cp .build/release/burnzombies "$bundle/Contents/MacOS/burnzombies"
cp -R .build/release/BurnZombies_BurnApp.bundle "$bundle/Contents/Resources/"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.burnzombies.app</string>
<key>CFBundleName</key><string>BurnZombies</string>
<key>CFBundleExecutable</key><string>BurnZombiesApp</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$bundle/Contents/MacOS/burnzombies"
codesign --force --sign - "$bundle"
echo "Built $bundle (local ad-hoc signature; not notarized)."
