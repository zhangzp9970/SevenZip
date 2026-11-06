#!/bin/bash
set -euo pipefail
native_dir="$(cd "$(dirname "$0")" && pwd)"
package_dir="$(cd "$native_dir/.." && pwd)"
source_root="$package_dir/vendor/7zip"
build_dir="$package_dir/.build/native"
mkdir -p "$build_dir/objects"
make -C "$source_root/CPP/7zip/Bundles/Format7zF" -f "$native_dir/Native.mak" \
    -j "${SEVENZIP_BUILD_JOBS:-6}" native \
    O="$build_dir/objects" BRIDGE_DIR="$native_dir" SEVENZIP_SOURCE_ROOT="$source_root" \
    NATIVE_OUTPUT="$build_dir/libSevenZip.dylib"
printf 'Built %s\n' "$build_dir/libSevenZip.dylib"
