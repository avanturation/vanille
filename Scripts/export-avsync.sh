#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
mkdir -p "$PROJECT_DIR/build/module-cache"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos15.0 -module-cache-path "$PROJECT_DIR/build/module-cache" \
 "$PROJECT_DIR/Tests/AirPlayBridge/AVSyncAnalysis.swift" "$PROJECT_DIR/Tests/AVSyncExport/main.swift" -o "$PROJECT_DIR/build/VanilleAVSyncExport"
"$PROJECT_DIR/build/VanilleAVSyncExport" "$@"
