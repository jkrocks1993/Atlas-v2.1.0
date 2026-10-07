#!/bin/bash
set -euo pipefail
APP="/Applications/Atlas.app"
[[ -d "$APP" ]] || { echo "ERROR: Atlas.app not found."; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
echo "ATLAS version: $VERSION"
echo "ATLAS build:   $BUILD"
echo "Bundle ID:     $ID"
[[ "$VERSION" == "2.1.1" && "$BUILD" == "15" ]] || { echo "ERROR: Version/build mismatch."; exit 1; }
echo "OK: ATLAS v2.1.1 build 15 is installed."
