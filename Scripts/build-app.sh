#!/bin/bash
# Build a runnable .app without an Xcode project. Debug is the "Spare Dev" channel
# (app.spare.dev), Release is "Spare" (app.spare) — same split as project.yml.
#
#   Scripts/build-app.sh [Debug|Release]
#
# Release is a universal binary (Apple silicon and Intel). The version comes from project.yml;
# SPARE_VERSION and SPARE_BUILD override it for a one-off build.
#
# Signing, first match wins:
#   SPARE_SIGN_IDENTITY="Developer ID Application: …"  hardened runtime + secure timestamp, the
#                                                      signature notarization accepts
#   SPARE_SIGN=1                                       the local "Spare Self-Signed" identity
#   neither                                            ad-hoc
set -uo pipefail
cd "$(dirname "$0")/.."

config="${1:-Debug}"
case "$config" in
    Debug) name="Spare Dev"; bundle_id="app.spare.dev"; opt="-Onone"; archs="arm64" ;;
    Release) name="Spare"; bundle_id="app.spare"; opt="-Osize"; archs="arm64 x86_64" ;;
    *) echo "usage: $0 [Debug|Release]"; exit 1 ;;
esac

# One place for the version: project.yml, which Xcode builds read too.
setting() { sed -n "s/^ *$1: *\"\(.*\)\"/\1/p" project.yml | head -1; }
version="${SPARE_VERSION:-$(setting MARKETING_VERSION)}"
build="${SPARE_BUILD:-$(setting CURRENT_PROJECT_VERSION)}"
minimum="26.0"

out="build/$config"
app="$out/$name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$out/obj"

sdk="$(xcrun --show-sdk-path --sdk macosx)"
slices=()
for arch in $archs; do
    slice="$out/obj/Spare-$arch"
    if ! swiftc -swift-version 6 "$opt" -sdk "$sdk" -target "$arch-apple-macos$minimum" \
        -framework AppKit -framework ImageIO -framework ServiceManagement \
        -lsqlite3 \
        $(find Spare -name '*.swift') -o "$slice"; then
        echo "FAIL  $config ($arch) did not build"
        exit 1
    fi
    slices+=("$slice")
done
lipo -create "${slices[@]}" -output "$app/Contents/MacOS/Spare" || exit 1
if [ "$config" = "Release" ]; then strip -rSTx "$app/Contents/MacOS/Spare"; fi

# Info.plist ships with Xcode build-setting placeholders; substitute them here.
sed -e 's|$(EXECUTABLE_NAME)|Spare|' \
    -e "s|\$(PRODUCT_BUNDLE_IDENTIFIER)|$bundle_id|" \
    -e "s|\$(PRODUCT_NAME)|$name|" \
    -e "s|\$(MARKETING_VERSION)|$version|" \
    -e "s|\$(CURRENT_PROJECT_VERSION)|$build|" \
    -e "s|\$(MACOSX_DEPLOYMENT_TARGET)|$minimum|" \
    Spare/Info.plist > "$app/Contents/Info.plist"

# The icon is an Icon Composer document: actool turns it into the Liquid Glass asset macOS 26
# draws, plus an .icns for anything older that reads the bundle. actool ships with Xcode only,
# and resolves relative paths against its input rather than the working directory;
# without it the app still builds, with the generic icon.
if xcrun --find actool >/dev/null 2>&1; then
    if ! xcrun actool "$PWD/Spare/AppIcon.icon" --compile "$PWD/$app/Contents/Resources" \
        --platform macosx --minimum-deployment-target "$minimum" --target-device mac \
        --app-icon AppIcon --output-partial-info-plist "$PWD/$out/obj/icon.plist" \
        --errors --warnings >/dev/null ||
        [ ! -f "$app/Contents/Resources/Assets.car" ]; then
        echo "FAIL  the app icon did not compile"
        exit 1
    fi
else
    echo "warn  actool not found (Xcode not installed): building without the app icon"
fi

entitlements=Spare/Spare.entitlements
signed=""
if [ -n "${SPARE_SIGN_IDENTITY:-}" ]; then
    # No fallback here: a release that silently went out ad-hoc is worse than a failed build.
    if ! codesign --force --options runtime --timestamp --sign "$SPARE_SIGN_IDENTITY" \
        --entitlements "$entitlements" "$app"; then
        echo "FAIL  signing with '$SPARE_SIGN_IDENTITY' failed"
        exit 1
    fi
    signed="$SPARE_SIGN_IDENTITY"
# The stable identity keeps the Accessibility grant across rebuilds; an ad-hoc
# signature changes every build and silently drops it. Signing with it needs a
# keychain unlock that blocks forever without someone at the screen, so it is
# opt-in: run `SPARE_SIGN=1 Scripts/build-app.sh` once from a terminal and click
# Always Allow.
elif [ "${SPARE_SIGN:-0}" = "1" ] && security find-identity -p codesigning | grep -q "Spare Self-Signed"; then
    if codesign --force --sign "Spare Self-Signed" --timestamp=none \
        --entitlements "$entitlements" "$app" 2>/dev/null; then
        signed="Spare Self-Signed"
    else
        echo "warn  signing with 'Spare Self-Signed' failed, falling back to ad-hoc"
    fi
fi
if [ -z "$signed" ]; then
    # Release runs under the hardened runtime even unsigned, so a local build behaves like the
    # notarized one.
    runtime=()
    if [ "$config" = "Release" ]; then runtime=(--options runtime); fi
    codesign --force "${runtime[@]}" --sign - --entitlements "$entitlements" "$app" || exit 1
    signed="ad-hoc"
fi

echo "ok    $app $version ($build), $archs, $signed"
