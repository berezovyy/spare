#!/bin/bash
# Package the Release app as dist/Spare-<version>.dmg, with its SHA-256 next to it.
#
#   Scripts/build-dmg.sh
#
# What the DMG is good for depends on what the environment provides:
#   SPARE_SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)". Signs the app and the DMG.
#   SPARE_NOTARY_PROFILE  a notarytool keychain profile, saved once with
#                         `xcrun notarytool store-credentials <profile> --apple-id … --team-id …`.
#                         Notarizes and staples both, so Gatekeeper opens them offline.
# With both, the DMG can be published. With neither, it opens only on this Mac: anywhere else
# Gatekeeper refuses an ad-hoc signature.
#
# SPARE_VERSION / SPARE_BUILD override project.yml's version, as in build-app.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

identity="${SPARE_SIGN_IDENTITY:-}"
profile="${SPARE_NOTARY_PROFILE:-}"
if [ -n "$profile" ] && [ -z "$identity" ]; then
    echo "x SPARE_NOTARY_PROFILE needs SPARE_SIGN_IDENTITY: Apple notarizes Developer ID signatures only" >&2
    exit 1
fi

./Scripts/build-app.sh Release
app="build/Release/Spare.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
work="build/Release/package"
rm -rf "$work"
mkdir -p "$work" dist

# Submits a file and waits. `--wait` exits 0 for a rejected submission too, so the status is read.
notarize() {
    local result status id
    echo "> Notarizing $(basename "$1")"
    result="$(xcrun notarytool submit "$1" --keychain-profile "$profile" --wait --output-format json)"
    status="$(plutil -extract status raw - <<<"$result" 2>/dev/null || echo unknown)"
    if [ "$status" != "Accepted" ]; then
        id="$(plutil -extract id raw - <<<"$result" 2>/dev/null || true)"
        echo "x notarization: $status" >&2
        if [ -n "$id" ]; then xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true; fi
        exit 1
    fi
}

if [ -n "$profile" ]; then
    # The app gets its own ticket so it still opens offline once it is out of the DMG.
    ditto -c -k --keepParent "$app" "$work/Spare.zip"
    notarize "$work/Spare.zip"
    xcrun stapler staple -q "$app"
fi

dmg="dist/Spare-$version.dmg"
echo "> Packaging $dmg"
stage="$work/stage"
mkdir -p "$stage"
ditto "$app" "$stage/Spare.app"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -srcfolder "$stage" -format ULFO -volname "Spare $version" -fs APFS -quiet "$dmg"

if [ -n "$identity" ]; then
    codesign --force --timestamp --sign "$identity" "$dmg"
fi
if [ -n "$profile" ]; then
    notarize "$dmg"
    xcrun stapler staple -q "$dmg"
    spctl --assess --type open --context context:primary-signature "$dmg"
    spctl --assess --type execute "$app"
    status="notarized"
elif [ -n "$identity" ]; then
    status="signed, NOT notarized: Gatekeeper will still warn"
else
    status="unsigned: opens on this Mac only"
fi

(cd dist && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
rm -rf "$work"
echo "  app $(du -sk "$app" | cut -f1) KB, dmg $(($(stat -f%z "$dmg") / 1024)) KB"
echo "  sha256 $(cut -d' ' -f1 "$dmg.sha256")"
echo "v $dmg ($status)"
