#!/bin/bash
set -euo pipefail

# Resolve project paths relative to this script, even when invoked elsewhere.
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
APP_ROOT="$PWD"
SEVENZIP_SOURCE_ROOT="$APP_ROOT/vendor/7zip"
BUILD_ROOT="$APP_ROOT/.build"
APP_BUNDLE="$APP_ROOT/dist/SevenZip.app"
ARCH=arm64

printf '构建工程：%s\n输出目录：%s\n' "$APP_ROOT" "$APP_ROOT/dist"

if [[ "$(uname -s)" != Darwin ]]; then
    echo "请在 macOS 13 或更高版本上构建 SevenZip。" >&2
    exit 1
fi
if ! xcrun --find swift >/dev/null 2>&1; then
    echo "请先运行 xcode-select --install，安装 Apple Command Line Tools。" >&2
    exit 1
fi
SDK_PATH="$(xcrun --show-sdk-path)"
SDK_VERSION="$(xcrun --show-sdk-version)"
ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP_ROOT/Resources/Info.plist")"
ICON_NAME="${ICON_NAME%.icns}"

mkdir -p "$BUILD_ROOT/module-cache" "$BUILD_ROOT/swiftpm-cache" \
    "$BUILD_ROOT/swiftpm-config" "$BUILD_ROOT/swiftpm-security" \
    "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/Licenses" \
    "$APP_BUNDLE/Contents/Frameworks"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/module-cache"
export MACOSX_DEPLOYMENT_TARGET=13.0

# Build the C ABI library from the repository's actual archive/codec sources.
echo "[1/4] 编译 arm64 动态库…"
bash "$APP_ROOT/Native/build-native.sh"

echo "[2/4] 编译 SevenZip 界面…"
SWIFT_OPTIONS=(--package-path "$APP_ROOT" --scratch-path "$BUILD_ROOT" \
    --cache-path "$BUILD_ROOT/swiftpm-cache" --config-path "$BUILD_ROOT/swiftpm-config" \
    --security-path "$BUILD_ROOT/swiftpm-security" --sdk "$SDK_PATH" \
    --triple arm64-apple-macosx13.0 -c release)
# Some Command Line Tools / Swift Build combinations record the deployment
# target as the linked SDK. AppKit uses this field to select its design, so
# pass the actual SDK version independently of our minimum supported macOS.
swift build "${SWIFT_OPTIONS[@]}" --product SevenZip \
    -Xswiftc -module-cache-path -Xswiftc "$BUILD_ROOT/module-cache" \
    -Xlinker -platform_version -Xlinker macos -Xlinker 13.0 -Xlinker "$SDK_VERSION"
BIN_DIR="$(swift build "${SWIFT_OPTIONS[@]}" --show-bin-path)"

echo "[3/4] 打包应用和图标…"
cp "$BIN_DIR/SevenZip" "$APP_BUNDLE/Contents/MacOS/SevenZip"
cp "$BUILD_ROOT/native/libSevenZip.dylib" "$APP_BUNDLE/Contents/Frameworks/libSevenZip.dylib"
# Remove the old generated CLI from packages built with the previous version.
if [[ -f "$APP_BUNDLE/Contents/Resources/7zz" ]]; then
    mv "$APP_BUNDLE/Contents/Resources/7zz" "$BUILD_ROOT/legacy-7zz"
fi
for locale in "$APP_ROOT"/Resources/*.lproj; do
    [[ -d "$locale" ]] && ditto "$locale" "$APP_BUNDLE/Contents/Resources/$(basename "$locale")"
done
cp "$APP_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$SEVENZIP_SOURCE_ROOT/DOC/License.txt" "$SEVENZIP_SOURCE_ROOT/DOC/copying.txt" \
    "$SEVENZIP_SOURCE_ROOT/DOC/unRarLicense.txt" "$APP_BUNDLE/Contents/Resources/Licenses/"
cp "$APP_ROOT/LICENSE" "$APP_BUNDLE/Contents/Resources/Licenses/SevenZip-GPL-3.0.txt"
chmod 755 "$APP_BUNDLE/Contents/MacOS/SevenZip" "$APP_BUNDLE/Contents/Frameworks/libSevenZip.dylib"
swift -module-cache-path "$BUILD_ROOT/module-cache" \
    "$APP_ROOT/Resources/GenerateIcon.swift" "$BUILD_ROOT/AppIcon.iconset" \
    "$APP_BUNDLE/Contents/Resources/$ICON_NAME.icns"
swift -module-cache-path "$BUILD_ROOT/module-cache" \
    "$APP_ROOT/Resources/GenerateDocumentIcons.swift" "$APP_ROOT/Resources/Info.plist" \
    "$APP_BUNDLE/Contents/Resources" "$BUILD_ROOT/DocumentIconPreviews"
# An earlier build used a stable icon filename, which macOS can keep cached.
# Keep the previous generated resource outside the bundle after the rename.
if [[ "$ICON_NAME" != AppIcon && -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]]; then
    mv "$APP_BUNDLE/Contents/Resources/AppIcon.icns" "$BUILD_ROOT/AppIcon.previous.icns"
fi
plutil -lint "$APP_BUNDLE/Contents/Info.plist"

echo "[4/4] 本地签名并验证…"
for binary in "$APP_BUNDLE/Contents/MacOS/SevenZip" "$APP_BUNDLE/Contents/Frameworks/libSevenZip.dylib"; do
    [[ "$(lipo -archs "$binary")" == arm64 ]] || { echo "Expected arm64-only binary: $binary" >&2; exit 1; }
    linked_sdk="$(otool -l "$binary" | awk '$1 == "sdk" && !seen { print $2; seen = 1 }')"
    [[ "${linked_sdk%%.*}" == "${SDK_VERSION%%.*}" ]] || { echo "Incorrect linked SDK $linked_sdk: $binary" >&2; exit 1; }
done
codesign --force --sign - "$APP_BUNDLE/Contents/Frameworks/libSevenZip.dylib"
codesign --force --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
# Updating files inside an existing bundle doesn't change its root timestamp.
# Mark this build as new so Finder/Launch Services can notice the replacement.
touch "$APP_BUNDLE"
echo "已生成：$APP_BUNDLE"
echo "此构建为本地开发包（ad-hoc 签名，未公证）。"
