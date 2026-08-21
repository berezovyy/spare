#!/bin/bash
# Package the Release app as dist/Spare-<version>.dmg. Usage: ./Scripts/build-dmg.sh [version]
#
# Two build paths, and the script says which one it took:
#   xcodebuild  — the real thing, when full Xcode is installed.
#   build-app.sh — Command-Line-Tools-only machines. Same sources, same bundle id
#                  (app.spare); it just cannot honour a MARKETING_VERSION override.
# Either way the Debug channel (app.spare.dev) is untouched: Release is its own bundle id.
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
IDENTITY="Spare Self-Signed"
DERIVED="build/DerivedData"

if ! security find-identity -p codesigning | grep -q "$IDENTITY"; then
    echo "x '$IDENTITY' code-signing identity not found — create it once before releasing." >&2
    exit 1
fi

if xcodebuild -version >/dev/null 2>&1; then
    echo "> Building Spare.app (Release) with xcodebuild"
    xcodegen generate
    # --timestamp=none: a self-signed identity has no trusted timestamp authority.
    xcodebuild -project Spare.xcodeproj -scheme Spare -configuration Release \
        -derivedDataPath "$DERIVED" \
        CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
        OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
        ${1:+MARKETING_VERSION="$1"} \
        build
    APP="$DERIVED/Build/Products/Release/Spare.app"
else
    echo "> xcodebuild unavailable (Command Line Tools only) — building with Scripts/build-app.sh"
    if [ $# -gt 0 ]; then echo "  note: version override '$1' ignored on this path" >&2; fi
    # SPARE_SIGN is forwarded, not forced: signing with the identity needs a keychain
    # unlock that blocks forever with nobody at the screen. Unset, build-app.sh signs ad-hoc.
    ./Scripts/build-app.sh Release
    APP="build/Release/Spare.app"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="dist/Spare-${VERSION}.dmg"

echo "> Packaging ${DMG}"
mkdir -p dist
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -srcfolder "$STAGE" -format UDZO -volname "Spare" -quiet "$DMG"
rm -rf "$STAGE"

echo "  binary $(stat -f%z "$APP/Contents/MacOS/Spare") bytes, dmg $(stat -f%z "$DMG") bytes"
echo "v $DMG"
