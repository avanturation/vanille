#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
BUILD_DIR="${VANILLE_BUILD_DIR:-$PROJECT_DIR/build}"
mkdir -p "$BUILD_DIR/module-cache"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos15.0 \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$PROJECT_DIR/Vanille/Models/Models.swift" \
  "$PROJECT_DIR/Vanille/Utilities/Persistence.swift" \
  "$PROJECT_DIR/Vanille/Audio/Equalizer.swift" \
  "$PROJECT_DIR/Vanille/Audio/HAL.swift" \
  "$PROJECT_DIR/Vanille/Audio/AudioEngine.swift" \
  "$PROJECT_DIR/Tests/Offline/main.swift" -o "$BUILD_DIR/VanilleTests"
"$BUILD_DIR/VanilleTests"
