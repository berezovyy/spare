#!/bin/bash
# Build a runnable .app without Xcode. Debug is the "Spare Dev" channel
# (app.spare.dev), Release is "Spare" (app.spare) — same split as project.yml.
#
# Only for machines with just the Command Line Tools. When Xcode is present,
# `xcodebuild -scheme Spare -configuration Debug` is the real thing.
set -uo pipefail
cd "$(dirname "$0")/.."

config="${1:-Debug}"
case "$config" in
    Debug) name="Spare Dev"; bundle_id="app.spare.dev"; opt="-Onone" ;;
    Release) name="Spare"; bundle_id="app.spare"; opt="-Osize" ;;
    *) echo "usage: $0 [Debug|Release]"; exit 1 ;;
esac

out="build/$config"
app="$out/$name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

if ! swiftc -swift-version 6 "$opt" \
    -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    -target arm64-apple-macos26.0 \
    -framework AppKit -framework ImageIO -framework ServiceManagement \
    -lsqlite3 \
    $(find Spare -name '*.swift') -o "$app/Contents/MacOS/Spare"; then
    echo "FAIL  $config did not build"
    exit 1
fi

# Info.plist ships with Xcode build-setting placeholders; substitute them here.
sed -e 's|$(EXECUTABLE_NAME)|Spare|' \
    -e "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|$bundle_id|" \
    -e "s|\$(PRODUCT_NAME)|$name|" \
    -e 's|$(MARKETING_VERSION)|0.1.0|' \
    -e 's|$(CURRENT_PROJECT_VERSION)|1|' \
    -e 's|$(MACOSX_DEPLOYMENT_TARGET)|26.0|' \
    Spare/Info.plist > "$app/Contents/Info.plist"

# The icon is an Icon Composer document: actool turns it into the Liquid Glass asset macOS 26
# draws, plus an .icns for anything older that reads the bundle. actool ships with Xcode only,
# and resolves relative paths against its input rather than the working directory; without it
# the app still builds, with the generic icon.
if xcrun --find actool >/dev/null 2>&1; then
    if ! xcrun actool "$PWD/Spare/AppIcon.icon" --compile "$PWD/$app/Contents/Resources" \
        --platform macosx --minimum-deployment-target 26.0 --target-device mac \
        --app-icon AppIcon --output-partial-info-plist "$PWD/$out/icon.plist" \
        --errors --warnings >/dev/null ||
        [ ! -f "$app/Contents/Resources/Assets.car" ]; then
        echo "FAIL  the app icon did not compile"
        exit 1
    fi
else
    echo "warn  actool not found (Xcode not installed): building without the app icon"
fi

# The stable identity keeps the Accessibility grant across rebuilds; an ad-hoc
# signature changes every build and silently drops it. Signing with it needs a
# keychain unlock that blocks forever without someone at the screen, so it is
# opt-in: run `SPARE_SIGN=1 Scripts/build-app.sh` once from a terminal and click
# Always Allow. Guarded by a timeout so an unattended run can never wedge.
signed=""
if [ "${SPARE_SIGN:-0}" = "1" ] && security find-identity -p codesigning | grep -q "Spare Self-Signed"; then
    if codesign --force --sign "Spare Self-Signed" --timestamp=none \
        --entitlements Spare/Spare.entitlements "$app" 2>/dev/null; then
        signed="Spare Self-Signed"
    else
        echo "warn  signing with 'Spare Self-Signed' failed, falling back to ad-hoc"
    fi
fi
if [ -z "$signed" ]; then
    codesign --force --sign - --entitlements Spare/Spare.entitlements "$app" || exit 1
    signed="ad-hoc"
fi

echo "ok    $app ($signed)"
