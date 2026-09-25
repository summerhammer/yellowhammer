#!/usr/bin/env bash
# Verify a notarized, stapled app bundle. Re-run this on any copy of the app — after
# scripts/release/notarize.sh (P16.3), after packaging (P16.4), or on an installed copy
# (P16.6) — since notarization and stapling survive being moved or re-zipped.
#
# Checks, in order:
#   1. codesign --verify --deep --strict: the bundle and everything inside it verifies.
#   2. spctl --assess --type execute: Gatekeeper accepts it, and specifically because it
#      was notarized (source=Notarized Developer ID), not merely Developer ID signed.
#   3. xcrun stapler validate: the notarization ticket is stapled to the bundle.
#
# Usage: verify-notarized.sh <path-to-app>
set -euo pipefail

fail() {
	echo "::error title=Notarization check::$1"
	exit 1
}

[ $# -eq 1 ] || fail "Usage: $0 <path-to-app>"

APP_PATH="$1"
[ -d "$APP_PATH" ] || fail "App bundle does not exist: $APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH" \
	|| fail "codesign --verify --deep --strict failed for $APP_PATH"

spctl_output=$(spctl --assess --type execute --verbose=2 "$APP_PATH" 2>&1) \
	|| fail "spctl --assess rejected $APP_PATH: $spctl_output"
echo "$spctl_output"
echo "$spctl_output" | grep -q 'source=Notarized Developer ID' \
	|| fail "spctl did not report source=Notarized Developer ID for $APP_PATH: $spctl_output"

stapler_output=$(xcrun stapler validate "$APP_PATH" 2>&1) \
	|| fail "xcrun stapler validate failed for $APP_PATH: $stapler_output"
echo "$stapler_output"

echo "Notarization check passed: $APP_PATH is notarized (Developer ID) and carries a valid staple."
