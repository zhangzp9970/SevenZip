#!/bin/bash
# Real ArchiveEngine integration checks; Apple Command Line Tools are sufficient.
set -euo pipefail
CHECK_APP_ROOT="$(cd "$(dirname "$0")" && pwd)"
CHECK_BUILD_ROOT="$CHECK_APP_ROOT/.build/checks"
CHECK_ENGINE="${SEVENZIP_LIBRARY:-$CHECK_APP_ROOT/dist/SevenZip.app/Contents/Frameworks/libSevenZip.dylib}"
if [[ ! -f "$CHECK_ENGINE" ]]; then
    echo "Missing dynamic library: $CHECK_ENGINE" >&2
    echo "Run ./build.sh first, or set SEVENZIP_LIBRARY to libSevenZip.dylib." >&2
    exit 1
fi
mkdir -p "$CHECK_BUILD_ROOT/module-cache"
xcrun swiftc -target arm64-apple-macosx13.0 -I "$CHECK_APP_ROOT/BridgeAPI/include" -module-cache-path "$CHECK_BUILD_ROOT/module-cache" \
    "$CHECK_APP_ROOT/Sources/ArchiveCore/ArchiveEngine.swift" \
    "$CHECK_APP_ROOT/Checks/Smoke.swift" -o "$CHECK_BUILD_ROOT/Smoke"
"$CHECK_BUILD_ROOT/Smoke" "$CHECK_ENGINE"
