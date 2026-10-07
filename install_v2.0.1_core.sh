#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
EXPECTED_VERSION="2.1.2"
EXPECTED_BUILD="16"
APP="$ROOT/build/Atlas.app"
INSTALL_TARGET="/Applications/Atlas.app"
BACKUP_DIR="$HOME/Desktop/Atlas_Backups"

echo "=============================================="
echo "ATLAS v$EXPECTED_VERSION — Build $EXPECTED_BUILD"
echo "Offline ML / Human Feedback / Intel x86_64"
echo "=============================================="
echo "Source: $ROOT"
echo
echo "A clean Xcode DerivedData directory will be used."
echo

"$ROOT/build.sh"

[[ -d "$APP" ]] || { echo "ERROR: Verified build app not found: $APP"; exit 1; }
mkdir -p "$BACKUP_DIR"

if [[ -d "$INSTALL_TARGET" ]]; then
  BACKUP="$BACKUP_DIR/Atlas_before_v${EXPECTED_VERSION}_$(date +%Y%m%d_%H%M%S).app"
  echo "Backing up existing /Applications/Atlas.app…"
  cp -R "$INSTALL_TARGET" "$BACKUP"
  echo "Backup: $BACKUP"
fi

killall Atlas 2>/dev/null || true
killall MacFileInventory 2>/dev/null || true

echo "Installing to /Applications/Atlas.app…"
sudo rm -rf "$INSTALL_TARGET"
sudo ditto --rsrc --extattr --acl "$APP" "$INSTALL_TARGET"
sudo xattr -dr com.apple.quarantine "$INSTALL_TARGET" 2>/dev/null || true

INSTALLED=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALL_TARGET/Contents/Info.plist")
INSTALLED_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALL_TARGET/Contents/Info.plist")
INSTALLED_EXEC=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INSTALL_TARGET/Contents/Info.plist")

[[ "$INSTALLED" == "$EXPECTED_VERSION" ]] || { echo "ERROR: Installed version is $INSTALLED"; exit 1; }
[[ "$INSTALLED_BUILD" == "$EXPECTED_BUILD" ]] || { echo "ERROR: Installed build is $INSTALLED_BUILD"; exit 1; }
[[ "$INSTALLED_EXEC" == "Atlas" ]] || { echo "ERROR: Installed executable is $INSTALLED_EXEC"; exit 1; }

echo
echo "PASS: ATLAS v$EXPECTED_VERSION Build $EXPECTED_BUILD installed at:" 
echo "$INSTALL_TARGET"
echo
open "$INSTALL_TARGET"
