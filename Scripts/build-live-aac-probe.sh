#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/VanilleAACProbe.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
STAGED_APP="$STAGING_ROOT/VanilleAACProbe.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$PROJECT_DIR/build/module-cache"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos15.0 -module-cache-path "$PROJECT_DIR/build/module-cache" "$PROJECT_DIR/Tests/LowLatencyAAC/main.swift" -o "$STAGED_APP/Contents/MacOS/VanilleAACProbe"
cat > "$STAGED_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.avanturation.Vanille.AACLiveProbe</string><key>CFBundleName</key><string>Vanille live AAC probe</string><key>CFBundleExecutable</key><string>VanilleAACProbe</string><key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>15.0</string><key>NSPrincipalClass</key><string>NSApplication</string><key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict><key>NSLocalNetworkUsageDescription</key><string>Test Apple AirPlay playback of locally generated audio.</string></dict></plist>
PLIST
codesign --force --sign - "$STAGED_APP"
codesign --verify --strict "$STAGED_APP"
ditto --norsrc --noextattr "$STAGED_APP" "$PROJECT_DIR/build/VanilleAACProbe.app"
print "Built generated-AAC feasibility probe"
