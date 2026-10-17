#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
APP_PATH="${1:-$PROJECT_DIR/build/VanilleTestTone.app}"
mkdir -p "$APP_PATH/Contents/MacOS" "$PROJECT_DIR/build/module-cache"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos15.0 \
  -module-cache-path "$PROJECT_DIR/build/module-cache" \
  "$PROJECT_DIR/Tests/TestTone/main.swift" -o "$APP_PATH/Contents/MacOS/VanilleTestTone"
cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.avanturation.Vanille.TestTone</string>
<key>CFBundleName</key><string>Vanille Test Tone</string>
<key>CFBundleExecutable</key><string>VanilleTestTone</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
xattr -cr "$APP_PATH"
codesign --force --sign - "$APP_PATH"
print "Built $APP_PATH"
