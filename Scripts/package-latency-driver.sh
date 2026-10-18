#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
DESTINATION="${1:-$PROJECT_DIR/build/LatencyDriverDelivery}"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/VanilleLatencyInstaller.XXXXXX")"
PAYLOAD_ROOT="$STAGING_ROOT/Payload"
mkdir -p "$DESTINATION" "$PAYLOAD_ROOT/Library/Audio/Plug-Ins/HAL"
zsh "$PROJECT_DIR/Scripts/test-latency-driver.sh" | tee "$PROJECT_DIR/build/latency-driver-tests.txt"
ditto --norsrc --noextattr "$PROJECT_DIR/build/VanilleLatencyClock.driver" "$PAYLOAD_ROOT/Library/Audio/Plug-Ins/HAL/VanilleLatencyClock.driver"
codesign --verify --strict "$PAYLOAD_ROOT/Library/Audio/Plug-Ins/HAL/VanilleLatencyClock.driver"
chmod 755 "$PROJECT_DIR"/Scripts/DriverInstall/* "$PROJECT_DIR"/Scripts/DriverRemove/*
pkgbuild --analyze --root "$PAYLOAD_ROOT" "$STAGING_ROOT/Components.plist"
/usr/libexec/PlistBuddy -c 'Add :0:BundleIsRelocatable bool false' "$STAGING_ROOT/Components.plist"
/usr/libexec/PlistBuddy -c 'Add :0:BundleHasStrictIdentifier bool true' "$STAGING_ROOT/Components.plist"
pkgbuild --root "$PAYLOAD_ROOT" --install-location / --ownership recommended \
  --component-plist "$STAGING_ROOT/Components.plist" \
  --identifier com.avanturation.Vanille.LatencyClock.Installer --version 0.1.1 \
  --scripts "$PROJECT_DIR/Scripts/DriverInstall" "$DESTINATION/Update-Vanille-Video-Timing-0.1.1.pkg"
pkgbuild --nopayload --identifier com.avanturation.Vanille.LatencyClock.Remover --version 0.1.0 \
  --scripts "$PROJECT_DIR/Scripts/DriverRemove" "$DESTINATION/Remove-Vanille-Video-Timing.pkg"
cp "$PROJECT_DIR/build/latency-driver-checks.json" "$DESTINATION/DRIVER_CHECKS.json"
cp "$PROJECT_DIR/build/latency-driver-tests.txt" "$DESTINATION/DRIVER_CHECKS.txt"
ditto -c -k --sequesterRsrc --keepParent "$PAYLOAD_ROOT/Library/Audio/Plug-Ins/HAL/VanilleLatencyClock.driver" "$DESTINATION/VanilleLatencyClock.driver.zip"
print "Prepared experimental packages in $DESTINATION. Nothing has been installed."
