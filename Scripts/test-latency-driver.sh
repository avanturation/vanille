#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
mkdir -p "$PROJECT_DIR/build/module-cache"
zsh "$PROJECT_DIR/Scripts/build-latency-driver.sh"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos15.0 -module-cache-path "$PROJECT_DIR/build/module-cache" \
  -import-objc-header "$PROJECT_DIR/Driver/LatencyClock/AudioServerInterface.h" \
  "$PROJECT_DIR/Tests/LatencyClockDriver/main.swift" -o "$PROJECT_DIR/build/LatencyClockChecks"
VANILLE_DRIVER_REPORT="$PROJECT_DIR/build/latency-driver-checks.json" \
  "$PROJECT_DIR/build/LatencyClockChecks" "$PROJECT_DIR/build/VanilleLatencyClock.driver"
