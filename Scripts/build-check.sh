#!/bin/bash
# Compile and link every shipped source. Stands in for `xcodebuild build` on a
# machine that only has the Command Line Tools installed.
set -uo pipefail
cd "$(dirname "$0")/.."

out="${TMPDIR:-/tmp}/spare-build-check"
if ! swiftc -swift-version 6 \
    -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    -framework AppKit -framework ImageIO -framework ServiceManagement \
    -lsqlite3 \
    $(find Spare -name '*.swift') -o "$out"; then
    echo "FAIL  sources did not build"
    exit 1
fi
echo "ok    build"
