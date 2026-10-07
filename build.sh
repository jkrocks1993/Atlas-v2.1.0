#!/bin/bash
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

"$ROOT/preflight_v2.0.1.sh" || exit $?

DEST="${CONFIGURATION_BUILD_DIR:-$ROOT/build}"
DERIVED="$ROOT/.xcodeDerivedData"
rm -rf "$DEST" "$DERIVED"
mkdir -p "$DEST"
LOG="$ROOT/Build/atlas-xcodebuild.log"
mkdir -p "$(dirname "$LOG")"
rm -f "$LOG" "$ROOT/Build/atlas-build-errors.txt"

echo
echo "Building ATLAS v2.1.1 Build 15 for Intel x86_64…"
echo "Source root: $ROOT"
echo "DerivedData: $DERIVED"
echo

xcodebuild \
  -project "$ROOT/MacFileInventory.xcodeproj" \
  -scheme MacFileInventory \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -arch x86_64 \
  ARCHS=x86_64 \
  VALID_ARCHS=x86_64 \
  ONLY_ACTIVE_ARCH=YES \
  MACOSX_DEPLOYMENT_TARGET=13.0 \
  SWIFT_VERSION=5.0 \
  SWIFT_STRICT_CONCURRENCY=none \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=NO \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  PRODUCT_NAME=Atlas \
  PRODUCT_BUNDLE_IDENTIFIER=com.local.Atlas \
  CONFIGURATION_BUILD_DIR="$DEST" \
  build 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}

if [[ $STATUS -ne 0 ]]; then
  echo
  echo "============================================================"
  echo "ATLAS BUILD FAILED — actual compiler/linker errors:"
  echo "============================================================"
  grep -E 'error:|fatal error:|Undefined symbols|duplicate symbol|clang: error:' "$LOG" \
    | sed 's/^[[:space:]]*//' \
    | awk '!seen[$0]++' \
    > "$ROOT/Build/atlas-build-errors.txt" || true
  if [[ -s "$ROOT/Build/atlas-build-errors.txt" ]]; then
    cat "$ROOT/Build/atlas-build-errors.txt"
  else
    echo "No compiler error line was captured. Full log: $LOG"
  fi
  echo
  echo "Full build log: $LOG"
  exit "$STATUS"
fi

ATLAS_APP="$DEST/Atlas.app"
if [[ ! -d "$ATLAS_APP" ]]; then
  echo "ERROR: Xcode reported success but Atlas.app was not produced at $ATLAS_APP."
  exit 1
fi

PLIST="$ATLAS_APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
EXEC=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")
ARCHS_FOUND=$(lipo -archs "$ATLAS_APP/Contents/MacOS/$EXEC" 2>/dev/null || true)

[[ "$VERSION" == "2.1.1" ]] || { echo "ERROR: Built app version is $VERSION"; exit 1; }
[[ "$BUILD" == "15" ]] || { echo "ERROR: Built app build is $BUILD"; exit 1; }
[[ "$EXEC" == "Atlas" ]] || { echo "ERROR: Built executable is $EXEC"; exit 1; }
[[ "$ARCHS_FOUND" == "x86_64" ]] || { echo "ERROR: Built architecture is ${ARCHS_FOUND:-unknown}; expected x86_64"; exit 1; }

echo
echo "PASS: build artifact verified."
echo "Atlas.app: $ATLAS_APP"
echo "Version: $VERSION"
echo "Build: $BUILD"
echo "Executable: $EXEC"
echo "Architecture: $ARCHS_FOUND"
