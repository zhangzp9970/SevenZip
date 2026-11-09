#!/bin/bash
# Package an already-built arm64 app. Run ./build.sh first.
set -euo pipefail

# Every project path is relative to this script, not the caller's working directory.
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
PROJECT_ROOT="$PWD"
APP_BUNDLE="$PROJECT_ROOT/dist/SevenZip.app"
OUTPUT_DIR="$PROJECT_ROOT/dist"
STAGING_ROOT="$PROJECT_ROOT/.build/dmg"

if [[ "$(uname -s)" != Darwin ]]; then
    echo "DMG packaging requires macOS." >&2
    exit 1
fi
if (( $# > 1 )); then
    echo "Usage: ./package-dmg.sh [release-version]" >&2
    exit 1
fi
if [[ ! -f "$APP_BUNDLE/Contents/Info.plist" ]]; then
    echo "Missing dist/SevenZip.app. Run ./build.sh first." >&2
    exit 1
fi

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
MINIMUM_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_BUNDLE/Contents/Info.plist")"
RELEASE_VERSION="${1:-$APP_VERSION}"
# Restrict the version to a filename component, including CI prerelease suffixes.
if [[ ! "$RELEASE_VERSION" =~ ^[0-9][A-Za-z0-9.+_-]*$ ]] || (( ${#RELEASE_VERSION} > 100 )); then
    echo "Invalid release version: use a version such as 0.2.2 or 0.2.2-build.123.1." >&2
    exit 1
fi

for binary in "$APP_BUNDLE/Contents/MacOS/SevenZip" "$APP_BUNDLE/Contents/Frameworks/libSevenZip.dylib"; do
    if [[ ! -f "$binary" || "$(lipo -archs "$binary")" != arm64 ]]; then
        echo "Expected an arm64-only binary: $binary" >&2
        exit 1
    fi
done
codesign --verify --deep --strict "$APP_BUNDLE"

mkdir -p "$OUTPUT_DIR" "$STAGING_ROOT"
PACKAGE_TEMP="$(mktemp -d "$STAGING_ROOT/package.XXXXXX")"
cleanup() {
    # PACKAGE_TEMP is exclusively created by this invocation of mktemp.
    if [[ -d "$PACKAGE_TEMP" ]]; then
        rm -rf -- "$PACKAGE_TEMP"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

STAGE="$PACKAGE_TEMP/contents"
mkdir "$STAGE"
ditto "$APP_BUNDLE" "$STAGE/SevenZip.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Install.txt" <<EOF
SevenZip — 7-Zip for macOS

Drag SevenZip.app to Applications, then open SevenZip from Applications.
Requires an Apple Silicon Mac with macOS $MINIMUM_MACOS or later.

This build is ad-hoc signed and has not been notarized by Apple.
EOF
codesign --verify --deep --strict "$STAGE/SevenZip.app"

DMG_NAME="SevenZip-$RELEASE_VERSION-arm64.dmg"
TEMP_DMG="$PACKAGE_TEMP/$DMG_NAME"
OUTPUT_DMG="$OUTPUT_DIR/$DMG_NAME"
hdiutil create -volname SevenZip -srcfolder "$STAGE" -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 "$TEMP_DMG"
hdiutil verify -nocache "$TEMP_DMG"

# Prepare both files before replacing an earlier successful build.
DMG_SHA256="$(shasum -a 256 "$TEMP_DMG" | awk '{ print $1 }')"
printf '%s  %s\n' "$DMG_SHA256" "$DMG_NAME" > "$PACKAGE_TEMP/$DMG_NAME.sha256"
mv -f "$TEMP_DMG" "$OUTPUT_DMG"
mv -f "$PACKAGE_TEMP/$DMG_NAME.sha256" "$OUTPUT_DMG.sha256"
printf 'Generated: %s\nChecksum: %s\n' "$OUTPUT_DMG" "$OUTPUT_DMG.sha256"
