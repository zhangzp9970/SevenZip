#!/bin/bash
set -euo pipefail
SORTING_APP_ROOT="$(cd "$(dirname "$0")" && pwd)"
SORTING_BUILD_ROOT="$SORTING_APP_ROOT/.build/sorting-check"
mkdir -p "$SORTING_BUILD_ROOT/module-cache"
xcrun swiftc -module-cache-path "$SORTING_BUILD_ROOT/module-cache" \
    "$SORTING_APP_ROOT/Sources/SevenZip/BrowserSorting.swift" \
    "$SORTING_APP_ROOT/Checks/BrowserSortingSmoke.swift" \
    -o "$SORTING_BUILD_ROOT/BrowserSortingSmoke"
"$SORTING_BUILD_ROOT/BrowserSortingSmoke"
