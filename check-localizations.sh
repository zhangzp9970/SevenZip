#!/bin/bash
# Language checks use injected preferences; no system language changes are made.
set -euo pipefail
LOCALIZATION_APP_ROOT="$(cd "$(dirname "$0")" && pwd)"
LOCALIZATION_BUILD_ROOT="$LOCALIZATION_APP_ROOT/.build/localization-check"
LOCALIZATION_RESOURCES="${1:-$LOCALIZATION_APP_ROOT/Resources}"
mkdir -p "$LOCALIZATION_BUILD_ROOT/module-cache"
python3 "$LOCALIZATION_APP_ROOT/Resources/check-localizations.py"
xcrun swiftc -module-cache-path "$LOCALIZATION_BUILD_ROOT/module-cache" \
    "$LOCALIZATION_APP_ROOT/Sources/SevenZip/Localization.swift" \
    "$LOCALIZATION_APP_ROOT/Checks/LocalizationSmoke.swift" \
    -o "$LOCALIZATION_BUILD_ROOT/LocalizationSmoke"
"$LOCALIZATION_BUILD_ROOT/LocalizationSmoke" "$LOCALIZATION_RESOURCES"
