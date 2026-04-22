#!/usr/bin/env bash
# Build a Release .app and package it as a .zip suitable for a GitHub release.
# Usage: scripts/build-release.sh <version>
#   e.g. scripts/build-release.sh 0.1.0
#
# Output: dist/ClaudeSessions-<version>.zip
#
# The artifact is locally code-signed ("-") and not notarized. First-launch
# requires right-click -> Open to bypass Gatekeeper.

set -euo pipefail

VERSION="${1:?version required, e.g. 0.1.0}"

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

DERIVED="$ROOT/build/derived"
DIST="$ROOT/dist"
mkdir -p "$DIST"
rm -rf "$DERIVED"

xcodebuild \
    -project ClaudeSessions.xcodeproj \
    -scheme ClaudeSessions \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$VERSION" \
    build | tail -3

APP="$DERIVED/Build/Products/Release/ClaudeSessions.app"
if [[ ! -d "$APP" ]]; then
    echo "Build did not produce $APP" >&2
    exit 1
fi

ZIP="$DIST/ClaudeSessions-$VERSION.zip"
rm -f "$ZIP"
# ditto preserves bundle structure, code signature, and resource forks
# in the way macOS expects for distributable .app bundles.
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Built: $ZIP"
shasum -a 256 "$ZIP"
