#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
APP_PATH="${1:-$PROJECT_DIR/build/VanilleTestTone.app}"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/VanilleToneBuild.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
STAGED_APP="$STAGING_ROOT/VanilleTestTone.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$PROJECT_DIR/build/module-cache" "${APP_PATH:h}"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos15.0 \
  -module-cache-path "$PROJECT_DIR/build/module-cache" \
  "$PROJECT_DIR/Tests/TestTone/main.swift" -o "$STAGED_APP/Contents/MacOS/VanilleTestTone"
cat > "$STAGED_APP/Contents/Info.plist" <<'PLIST'
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
codesign --force --sign - "$STAGED_APP"
SECOND_STAGED="$STAGING_ROOT/VanilleTestToneB.app"
ditto --norsrc --noextattr "$STAGED_APP" "$SECOND_STAGED"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.avanturation.Vanille.TestToneB' "$SECOND_STAGED/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Vanille Test Tone B' "$SECOND_STAGED/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :VanilleTestFrequency real 440' "$SECOND_STAGED/Contents/Info.plist"
codesign --force --sign - "$SECOND_STAGED"
ditto --norsrc --noextattr "$STAGED_APP" "$APP_PATH"
ditto --norsrc --noextattr "$SECOND_STAGED" "${APP_PATH:h}/VanilleTestToneB.app"
print "Built native 1000 Hz and 440 Hz test fixtures"
