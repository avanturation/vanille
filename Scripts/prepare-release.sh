#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
RELEASE_DIR="${VANILLE_RELEASE_DIR:-$PROJECT_DIR/build/release}"
mkdir -p "$RELEASE_DIR"
VANILLE_DIAGNOSTICS=0 VANILLE_APP_PATH="$RELEASE_DIR/Vanille.app" VANILLE_ZIP_PATH="$RELEASE_DIR/Vanille-macos-arm64.zip" "$PROJECT_DIR/Scripts/build.sh"
"$PROJECT_DIR/Scripts/validate-release.sh" "$RELEASE_DIR/Vanille-macos-arm64.zip"
cp "$PROJECT_DIR/LICENSE" "$RELEASE_DIR/LICENSE"
cp "$PROJECT_DIR/RELEASE.md" "$RELEASE_DIR/RELEASE.md"
pushd "$RELEASE_DIR" >/dev/null
shasum -a 256 Vanille-macos-arm64.zip > SHA256SUMS.txt
popd >/dev/null
print "Local release candidate prepared in $RELEASE_DIR. Nothing has been published."
