#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
BUILD_DIR="${VANILLE_BUILD_DIR:-$PROJECT_DIR/build}"
APP_PATH="${VANILLE_APP_PATH:-$PROJECT_DIR/../Vanille.app}"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$BUILD_DIR/module-cache" "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
SOURCES=("$PROJECT_DIR"/Vanille/**/*.swift)
xcrun swiftc -O -whole-module-optimization -swift-version 5 \
  -target arm64-apple-macos15.0 -sdk "$SDK_PATH" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -module-name Vanille -framework AppKit -framework CoreAudio -framework AudioToolbox -framework ServiceManagement \
  "${SOURCES[@]}" -o "$APP_PATH/Contents/MacOS/Vanille"
cp "$PROJECT_DIR/Vanille/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
/usr/bin/xattr -cr "$APP_PATH"
/usr/bin/codesign --force --sign - --identifier com.avanturation.Vanille "$APP_PATH"
/usr/bin/codesign --verify --strict "$APP_PATH"
print "Built $APP_PATH"
