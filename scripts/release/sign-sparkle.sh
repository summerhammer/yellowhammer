#!/usr/bin/env bash
# Re-sign the embedded Sparkle.framework's helpers with the Developer ID identity, then
# re-seal the app. Used by release jobs between `xcodebuild ... -configuration Release`
# and scripts/release/verify-release-build.sh.
#
# Xcode's Code Sign On Copy signs the framework's own binary only. Sparkle's nested
# helpers (Autoupdate, Updater.app, Downloader.xpc, Installer.xpc) stay ad-hoc signed
# as the package ships them, and notarization rejects every one of them. They are signed
# inside-out, as Sparkle's documentation prescribes; Downloader.xpc keeps its
# entitlements. Re-signing the framework breaks the app's seal, so the app is re-signed
# last with its entitlements, requirements and flags preserved.
#
# Environment:
#   SIGNING_IDENTITY   codesign identity (default: "Developer ID Application: SUMMER HAMMER LLC
#                      (A2SJL2N487)")
#   KEYCHAIN_PATH      optional; passed to codesign as --keychain
#
# Usage: sign-sparkle.sh <path-to-app>
set -euo pipefail

fail() {
	echo "::error title=Sparkle signing::$1"
	exit 1
}

[ $# -eq 1 ] || fail "Usage: $0 <path-to-app>"
APP_PATH="$1"
SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework"
[ -d "$SPARKLE" ] || fail "no Sparkle.framework in $APP_PATH"

signing_identity="${SIGNING_IDENTITY:-Developer ID Application: SUMMER HAMMER LLC (A2SJL2N487)}"

codesign_args=(--force --sign "$signing_identity" --options runtime --timestamp)
if [ -n "${KEYCHAIN_PATH:-}" ]; then
	codesign_args+=(--keychain "$KEYCHAIN_PATH")
fi

sign() {
	codesign "${codesign_args[@]}" "$@" || fail "codesign failed for ${*: -1}"
}

sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign --preserve-metadata=entitlements,requirements,flags "$APP_PATH"

codesign --verify --deep --strict "$APP_PATH" || fail "codesign --verify --deep --strict failed for $APP_PATH"
echo "Sparkle signing passed: $SPARKLE and its helpers are signed by '$signing_identity'."
