#!/bin/bash
# Verify the built app bundle embeds the engine and is validly signed.
# Usage: verify_app_bundle.sh <path-to-app>
set -euo pipefail

fail() {
    echo "::error title=Bundle check::$1"
    exit 1
}

[[ $# -eq 1 ]] || fail "Usage: $0 <path-to-app>"

APP_PATH="$1"
YH_PATH="$APP_PATH/Contents/MacOS/yh"

[[ -d "$APP_PATH" ]] || fail "App bundle does not exist: $APP_PATH"
[[ -f "$YH_PATH" ]] || fail "Engine binary not found at Contents/MacOS/yh in $APP_PATH"
[[ -x "$YH_PATH" ]] || fail "Engine binary at Contents/MacOS/yh is not executable"

codesign --verify --deep --strict --verbose=2 "$APP_PATH" \
    || fail "codesign --verify --deep --strict failed for $APP_PATH"
codesign --verify --strict --verbose=2 "$YH_PATH" \
    || fail "codesign --verify --strict failed for the embedded Contents/MacOS/yh"

echo "Bundle check passed: $APP_PATH contains Contents/MacOS/yh and verifies under codesign --deep --strict"
