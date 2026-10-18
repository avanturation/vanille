#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
BUILD_DIR="${VANILLE_BUILD_DIR:-$PROJECT_DIR/build}"
APP_PATH="${VANILLE_APP_PATH:-$BUILD_DIR/Vanille.app}"
ZIP_PATH="${VANILLE_ZIP_PATH:-${APP_PATH%.app}-macos-arm64.zip}"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/VanilleBuild.XXXXXX")"
STAGED_APP="$STAGING_ROOT/Vanille.app"
trap 'rm -rf "$STAGING_ROOT"' EXIT
mkdir -p "$BUILD_DIR/module-cache" "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources" "${APP_PATH:h}"
SOURCES=("$PROJECT_DIR"/Vanille/**/*.swift)
EXTRA_FLAGS=()
if [[ "${VANILLE_DIAGNOSTICS:-0}" == "1" ]]; then
  EXTRA_FLAGS=(-D VANILLE_DIAGNOSTICS)
  SOURCES+=("$PROJECT_DIR/Tests/Live/LiveVerification.swift")
fi
xcrun swiftc -O -whole-module-optimization -swift-version 5 \
  -target arm64-apple-macos15.0 -sdk "$SDK_PATH" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -module-name Vanille -framework AppKit -framework CoreAudio -framework AudioToolbox -framework ServiceManagement \
  "${EXTRA_FLAGS[@]}" "${SOURCES[@]}" -o "$STAGED_APP/Contents/MacOS/Vanille"
cp "$PROJECT_DIR/Vanille/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
APP_VERSION="$(sed -n 's/^MARKETING_VERSION = //p' "$PROJECT_DIR/Config/Version.xcconfig")"
APP_BUILD="$(sed -n 's/^CURRENT_PROJECT_VERSION = //p' "$PROJECT_DIR/Config/Version.xcconfig")"
[[ "$APP_VERSION" == <->.<->.<-> && "$APP_BUILD" == <-> ]] || { print -u2 "Invalid app version configuration"; exit 1; }
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD" "$STAGED_APP/Contents/Info.plist"
cp "$PROJECT_DIR/LICENSE" "$STAGED_APP/Contents/Resources/LICENSE.txt"
/usr/bin/codesign --force --sign - --identifier com.avanturation.Vanille "$STAGED_APP"
/usr/bin/codesign --verify --strict "$STAGED_APP"
# Sign outside iCloud Drive: File Provider may attach FinderInfo to bundles in Documents.
# The archive is created from the verified, metadata-free staging bundle.
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$STAGED_APP" "$ZIP_PATH"
/usr/bin/ditto --norsrc --noextattr "$STAGED_APP" "$APP_PATH"
/usr/bin/xattr -cr "$APP_PATH" || true
print "Built $APP_PATH"
print "Archived $ZIP_PATH"
