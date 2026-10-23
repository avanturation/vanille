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
PULSE_STAGED="$STAGING_ROOT/VanilleTestPulse.app"
ditto --norsrc --noextattr "$STAGED_APP" "$PULSE_STAGED"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.avanturation.Vanille.TestPulse' "$PULSE_STAGED/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Vanille Test Pulse' "$PULSE_STAGED/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :VanilleTestPulsed bool true' "$PULSE_STAGED/Contents/Info.plist"
codesign --force --sign - "$PULSE_STAGED"
TRANSIENT_STAGED="$STAGING_ROOT/VanilleTestTransient.app"
ditto --norsrc --noextattr "$PULSE_STAGED" "$TRANSIENT_STAGED"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.avanturation.Vanille.TestTransient' "$TRANSIENT_STAGED/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Vanille Test Transient' "$TRANSIENT_STAGED/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :VanilleTestFrequency real 440' "$TRANSIENT_STAGED/Contents/Info.plist"
codesign --force --sign - "$TRANSIENT_STAGED"
HELPER_STAGED="$STAGED_APP/Contents/Helpers/VanilleHelper.app"
mkdir -p "${HELPER_STAGED:h}"
ditto --norsrc --noextattr "$SECOND_STAGED" "$HELPER_STAGED"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.avanturation.Vanille.TestTone.Helper' "$HELPER_STAGED/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Vanille Test Helper' "$HELPER_STAGED/Contents/Info.plist"
codesign --force --sign - "$HELPER_STAGED"
codesign --force --sign - "$STAGED_APP"
ditto --norsrc --noextattr "$STAGED_APP" "$APP_PATH"
ditto --norsrc --noextattr "$SECOND_STAGED" "${APP_PATH:h}/VanilleTestToneB.app"
ditto --norsrc --noextattr "$PULSE_STAGED" "${APP_PATH:h}/VanilleTestPulse.app"
ditto --norsrc --noextattr "$TRANSIENT_STAGED" "${APP_PATH:h}/VanilleTestTransient.app"
print "Built native 1000 Hz and 440 Hz test fixtures"
