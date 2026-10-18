#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/VanilleLatencyClock.XXXXXX")"
STAGED_DRIVER="$STAGING_ROOT/VanilleLatencyClock.driver"
mkdir -p "$STAGED_DRIVER/Contents/MacOS" "$PROJECT_DIR/build/module-cache"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos15.0 -module-cache-path "$PROJECT_DIR/build/module-cache" \
  -import-objc-header "$PROJECT_DIR/Driver/LatencyClock/AudioServerInterface.h" \
  -emit-library -module-name VanilleLatencyClock -Xlinker -install_name -Xlinker @loader_path/VanilleLatencyClock \
  -Xlinker -exported_symbol -Xlinker _VanilleLatencyClockFactory \
  "$PROJECT_DIR/Driver/LatencyClock/LatencyClockDriver.swift" -o "$STAGED_DRIVER/Contents/MacOS/VanilleLatencyClock"
cp "$PROJECT_DIR/Driver/LatencyClock/Info.plist" "$STAGED_DRIVER/Contents/Info.plist"
plutil -lint "$STAGED_DRIVER/Contents/Info.plist"
codesign --force --sign - "$STAGED_DRIVER"
codesign --verify --strict "$STAGED_DRIVER"
ditto --norsrc --noextattr "$STAGED_DRIVER" "$PROJECT_DIR/build/VanilleLatencyClock.driver"
print "Built $PROJECT_DIR/build/VanilleLatencyClock.driver (not installed)"
