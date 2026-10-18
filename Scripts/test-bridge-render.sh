#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
mkdir -p "$PROJECT_DIR/build/module-cache"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos15.0 -module-cache-path "$PROJECT_DIR/build/module-cache" \
 "$PROJECT_DIR/Vanille/Models/Models.swift" "$PROJECT_DIR/Vanille/Models/OutputGroup.swift" \
 "$PROJECT_DIR/Vanille/Audio/HAL.swift" "$PROJECT_DIR/Vanille/Audio/DeviceManager.swift" "$PROJECT_DIR/Vanille/Audio/Equalizer.swift" \
 "$PROJECT_DIR/Tests/AirPlayBridge/AVSyncAnalysis.swift" "$PROJECT_DIR/Tests/AirPlayBridge/HardwareTiming.swift" \
 "$PROJECT_DIR/Tests/AirPlayBridge/PCMHistory.swift" "$PROJECT_DIR/Tests/AirPlayBridge/BridgeCapture.swift" \
 "$PROJECT_DIR/Tests/BridgeRenderOffline/main.swift" -o "$PROJECT_DIR/build/VanilleSplitRenderTests"
"$PROJECT_DIR/build/VanilleSplitRenderTests"
