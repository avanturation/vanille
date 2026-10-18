#!/bin/zsh
set -euo pipefail
[[ $# == 1 ]] || { print -u2 "Usage: $0 /path/to/Vanille.zip"; exit 1; }
ARCHIVE_PATH="${1:A}"
CHECK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/VanilleReleaseCheck.XXXXXX")"
trap 'rm -rf "$CHECK_ROOT"' EXIT
ditto -x -k "$ARCHIVE_PATH" "$CHECK_ROOT"
CHECK_APP="$CHECK_ROOT/Vanille.app"
[[ -d "$CHECK_APP" ]] || { print -u2 "The archive must contain Vanille.app"; exit 1; }
codesign --verify --strict "$CHECK_APP"
[[ "$(lipo -archs "$CHECK_APP/Contents/MacOS/Vanille")" == "arm64" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$CHECK_APP/Contents/Info.plist")" == "15.0" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$CHECK_APP/Contents/Info.plist")" == "true" ]]
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CHECK_APP/Contents/Info.plist")"
[[ "$APP_VERSION" == <->.<->.<-> ]]
[[ -f "$CHECK_APP/Contents/Resources/LICENSE.txt" ]]
[[ ! -d "$CHECK_APP/Contents/Frameworks" && ! -d "$CHECK_APP/Contents/PlugIns" ]]
strings "$CHECK_APP/Contents/MacOS/Vanille" > "$CHECK_ROOT/binary-strings.txt"
if rg -q 'Run Audio Verification|Run Multi-Output Verification|Vanille Video Output|Native Stream Checks' "$CHECK_ROOT/binary-strings.txt"; then
    print -u2 "Development-only menus or the virtual-output experiment leaked into the release"; exit 1
fi
print "PASS: arm64, macOS 15+, menu bar app, resolved version $APP_VERSION, license, strict archive signature, no diagnostic or virtual-output bundle"
print "Development build only. Developer ID signing and notarization are separate release gates."
