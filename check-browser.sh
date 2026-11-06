#!/bin/bash
set -euo pipefail
BROWSER_APP_ROOT="$(cd "$(dirname "$0")" && pwd)"
BROWSER_BUILD_ROOT="$BROWSER_APP_ROOT/.build/browser-check"
mkdir -p "$BROWSER_BUILD_ROOT/module-cache"
xcrun swiftc -module-cache-path "$BROWSER_BUILD_ROOT/module-cache" \
    "$BROWSER_APP_ROOT/Sources/SevenZip/BrowserHistory.swift" \
    "$BROWSER_APP_ROOT/Sources/SevenZip/TemporaryDocument.swift" \
    "$BROWSER_APP_ROOT/Checks/BrowserBehaviorSmoke.swift" \
    -o "$BROWSER_BUILD_ROOT/BrowserBehaviorSmoke"
"$BROWSER_BUILD_ROOT/BrowserBehaviorSmoke"
