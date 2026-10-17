#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
mkdir -p "$PROJECT_DIR/build/module-cache"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos15.0 -module-cache-path "$PROJECT_DIR/build/module-cache" \
 "$PROJECT_DIR/Tests/AirPlayBridge/PCMHistory.swift" "$PROJECT_DIR/Tests/AirPlayOffline/main.swift" -o "$PROJECT_DIR/build/VanilleAirPlayTests"
"$PROJECT_DIR/build/VanilleAirPlayTests"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos15.0 -module-cache-path "$PROJECT_DIR/build/module-cache" \
 "$PROJECT_DIR/Vanille/Models/Models.swift" "$PROJECT_DIR/Vanille/Models/OutputGroup.swift" "$PROJECT_DIR/Vanille/Audio/HAL.swift" \
 "$PROJECT_DIR/Tests/AirPlayBridge/MemoryHTTPServer.swift" "$PROJECT_DIR/Tests/AirPlayBridge/LiveSegments.swift" \
 "$PROJECT_DIR/Tests/AirPlaySegments/SegmentChecks.swift" "$PROJECT_DIR/Tests/AirPlaySegments/main.swift" -o "$PROJECT_DIR/build/VanilleAirPlaySegmentTests"
"$PROJECT_DIR/build/VanilleAirPlaySegmentTests"
