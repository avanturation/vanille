#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/VanilleRoutingBuild.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
STAGED_APP="$STAGING_ROOT/VanilleRoutingLab.app"
APP_PATH="$PROJECT_DIR/build/VanilleRoutingLab.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$PROJECT_DIR/build/module-cache"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos15.0 -module-cache-path "$PROJECT_DIR/build/module-cache" \
 "$PROJECT_DIR/Vanille/Models/Models.swift" "$PROJECT_DIR/Vanille/Models/OutputGroup.swift" "$PROJECT_DIR/Vanille/Audio/HAL.swift" "$PROJECT_DIR/Vanille/Audio/DeviceManager.swift" \
 "$PROJECT_DIR/Tests/RoutingLab/main.swift" -o "$STAGED_APP/Contents/MacOS/VanilleRoutingLab"
cat > "$STAGED_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.avanturation.Vanille.RoutingLab</string>
<key>CFBundleName</key><string>Vanille Routing Lab</string>
<key>CFBundleExecutable</key><string>VanilleRoutingLab</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$STAGED_APP"
ditto --norsrc --noextattr "$STAGED_APP" "$APP_PATH"
print "Built $APP_PATH"
