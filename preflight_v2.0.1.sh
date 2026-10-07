#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

EXPECTED_VERSION="2.1.4"
EXPECTED_BUILD="18"
PROJECT="MacFileInventory.xcodeproj/project.pbxproj"
XCODE_PROJECT="MacFileInventory.xcodeproj"
PLIST="MacFileInventory/Info.plist"
SCHEME="MacFileInventory.xcodeproj/xcshareddata/xcschemes/MacFileInventory.xcscheme"

echo "ATLAS v$EXPECTED_VERSION Build $EXPECTED_BUILD — source/project preflight"
echo

[[ -d "$XCODE_PROJECT" ]] || { echo "ERROR: Missing Xcode project bundle"; exit 1; }
[[ -f "$PROJECT" ]] || { echo "ERROR: Missing project.pbxproj"; exit 1; }
[[ -f "$PLIST" ]] || { echo "ERROR: Missing Info.plist"; exit 1; }
[[ -f "$SCHEME" ]] || { echo "ERROR: Missing shared scheme"; exit 1; }

PROJECT_VERSION=$(grep -m1 'MARKETING_VERSION = ' "$PROJECT" | sed 's/.*= //;s/;//')
PROJECT_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION = ' "$PROJECT" | sed 's/.*= //;s/;//')
PLIST_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
PLIST_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")

[[ "$PROJECT_VERSION" == "$EXPECTED_VERSION" ]] || { echo "ERROR: Project marketing version mismatch: $PROJECT_VERSION"; exit 1; }
[[ "$PROJECT_BUILD" == "$EXPECTED_BUILD" ]] || { echo "ERROR: Project build mismatch: $PROJECT_BUILD"; exit 1; }
[[ "$PLIST_VERSION" == "$EXPECTED_VERSION" ]] || { echo "ERROR: Info.plist version mismatch: $PLIST_VERSION"; exit 1; }
[[ "$PLIST_BUILD" == "$EXPECTED_BUILD" ]] || { echo "ERROR: Info.plist build mismatch: $PLIST_BUILD"; exit 1; }

PRODUCT_NAME=$(grep -m1 'PRODUCT_NAME = ' "$PROJECT" | sed 's/.*= //;s/;//')
BUNDLE_ID=$(grep -m1 'PRODUCT_BUNDLE_IDENTIFIER = ' "$PROJECT" | sed 's/.*= //;s/;//')
[[ "$PRODUCT_NAME" == "Atlas" ]] || { echo "ERROR: Xcode product name is $PRODUCT_NAME, expected Atlas"; exit 1; }
[[ "$BUNDLE_ID" == "com.local.Atlas" ]] || { echo "ERROR: bundle identifier is $BUNDLE_ID, expected com.local.Atlas"; exit 1; }


for f in \
  MacFileInventory/Detection/OfflineMLVerifier.swift \
  MacFileInventory/Detection/OfflinePairModel.swift \
  MacFileInventory/FeedbackStore.swift \
  MacFileInventory/Detection/DuplicateEngine.swift \
  MacFileInventory/Storage_ResultStore.swift \
  MacFileInventory/App/AppState.swift \
  MacFileInventory/UI/ResultsPane.swift
do
  [[ -f "$f" ]] || { echo "ERROR: Missing integrated source: $f"; exit 1; }
done

if command -v xcodebuild >/dev/null 2>&1; then
  xcodebuild -list -project "$XCODE_PROJECT" >/dev/null
else
  echo "WARNING: xcodebuild is not available here; project-file checks only."
fi

echo "PASS: project, scheme, source integration and version metadata are consistent."
