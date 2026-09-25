#!/usr/bin/env bash
# Verify a Release build carries the expected version and is validly Developer ID signed,
# in both the app and the embedded engine (Contents/MacOS/yh). Used by release jobs after
# `xcodebuild ... -configuration Release`.
#
# Usage: verify-release-build.sh <path-to-app> <marketing-version> <build-number>
set -euo pipefail

fail() {
	echo "::error title=Release build::$1"
	exit 1
}

[ $# -eq 3 ] || fail "Usage: $0 <path-to-app> <marketing-version> <build-number>"

APP_PATH="$1"
MARKETING_VERSION="$2"
BUILD_NUMBER="$3"
YH_PATH="$APP_PATH/Contents/MacOS/yh"

[ -d "$APP_PATH" ] || fail "App bundle does not exist: $APP_PATH"
[ -f "$YH_PATH" ] || fail "Engine binary not found at Contents/MacOS/yh in $APP_PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Version: app Info.plist ---
app_short_version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null) \
	|| fail "could not read CFBundleShortVersionString from $APP_PATH/Contents/Info.plist"
app_bundle_version=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$APP_PATH/Contents/Info.plist" 2>/dev/null) \
	|| fail "could not read CFBundleVersion from $APP_PATH/Contents/Info.plist"
app_bundle_id=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP_PATH/Contents/Info.plist" 2>/dev/null) \
	|| fail "could not read CFBundleIdentifier from $APP_PATH/Contents/Info.plist"

[ "$app_short_version" = "$MARKETING_VERSION" ] \
	|| fail "app CFBundleShortVersionString is '$app_short_version', expected '$MARKETING_VERSION'"
[ "$app_bundle_version" = "$BUILD_NUMBER" ] \
	|| fail "app CFBundleVersion is '$app_bundle_version', expected '$BUILD_NUMBER'"
[ "$app_bundle_id" = "dev.yellowhammer" ] \
	|| fail "app CFBundleIdentifier is '$app_bundle_id', expected 'dev.yellowhammer'"

# --- Version: yh's embedded __TEXT,__info_plist ---
yh_plist_tmp="$(mktemp -t yh-info-plist)"
trap 'rm -f "$yh_plist_tmp"' EXIT

if ! segedit "$YH_PATH" -extract __TEXT __info_plist "$yh_plist_tmp" 2>/dev/null; then
	fail "could not extract __TEXT,__info_plist from $YH_PATH"
fi

yh_short_version=$(plutil -extract CFBundleShortVersionString raw "$yh_plist_tmp" 2>/dev/null) \
	|| fail "could not read CFBundleShortVersionString from $YH_PATH's embedded Info.plist"
yh_bundle_version=$(plutil -extract CFBundleVersion raw "$yh_plist_tmp" 2>/dev/null) \
	|| fail "could not read CFBundleVersion from $YH_PATH's embedded Info.plist"
yh_bundle_id=$(plutil -extract CFBundleIdentifier raw "$yh_plist_tmp" 2>/dev/null) \
	|| fail "could not read CFBundleIdentifier from $YH_PATH's embedded Info.plist"

[ "$yh_short_version" = "$MARKETING_VERSION" ] \
	|| fail "yh CFBundleShortVersionString is '$yh_short_version', expected '$MARKETING_VERSION'"
[ "$yh_bundle_version" = "$BUILD_NUMBER" ] \
	|| fail "yh CFBundleVersion is '$yh_bundle_version', expected '$BUILD_NUMBER'"
[ "$yh_bundle_id" = "dev.yellowhammer.engine" ] \
	|| fail "yh CFBundleIdentifier is '$yh_bundle_id', expected 'dev.yellowhammer.engine'"

# --- Signing: Developer ID, hardened runtime, secure timestamp, matching identifier ---
check_signature() {
	local path="$1" expected_id="$2" label="$3"
	local info
	info=$(codesign -dvv "$path" 2>&1) || fail "codesign -dvv failed for $label ($path)"

	echo "$info" | grep -q '^Authority=Developer ID Application:' \
		|| fail "$label is not signed by a Developer ID Application identity: $path"

	echo "$info" | grep -q '^Timestamp=' \
		|| fail "$label has no secure timestamp: $path"

	local flags_line
	flags_line=$(echo "$info" | grep '^CodeDirectory ' || true)
	echo "$flags_line" | grep -q 'runtime' \
		|| fail "$label is not hardened-runtime signed (no 'runtime' flag): $path"

	local identifier
	identifier=$(echo "$info" | sed -nE 's/^Identifier=(.*)$/\1/p')
	[ "$identifier" = "$expected_id" ] \
		|| fail "$label codesign Identifier is '$identifier', expected '$expected_id'"
}

check_signature "$APP_PATH" "dev.yellowhammer" "app"
check_signature "$YH_PATH" "dev.yellowhammer.engine" "embedded yh"

# --- No get-task-allow entitlement ---
check_no_get_task_allow() {
	local path="$1" label="$2"
	local entitlements
	entitlements=$(codesign -d --entitlements - --xml "$path" 2>/dev/null || true)
	echo "$entitlements" | grep -q 'com.apple.security.get-task-allow' \
		&& fail "$label has com.apple.security.get-task-allow in its entitlements: $path"
	return 0
}

check_no_get_task_allow "$APP_PATH" "app"
check_no_get_task_allow "$YH_PATH" "embedded yh"

# --- Apple Silicon only ---
check_arm64_only() {
	local path="$1" label="$2"
	local archs
	archs=$(lipo -archs "$path" 2>&1) || fail "lipo -archs failed for $label: $path"
	[ "$archs" = "arm64" ] || fail "$label is not arm64-only (lipo -archs: '$archs'): $path"
}

APP_EXECUTABLE_NAME=$(/usr/libexec/PlistBuddy -c "Print CFBundleExecutable" "$APP_PATH/Contents/Info.plist" 2>/dev/null) \
	|| fail "could not read CFBundleExecutable from $APP_PATH/Contents/Info.plist"

check_arm64_only "$APP_PATH/Contents/MacOS/$APP_EXECUTABLE_NAME" "app"
check_arm64_only "$YH_PATH" "embedded yh"

# --- Deep verification, reusing the CI bundle check for the embed + strict verify ---
"$SCRIPT_DIR/../ci/verify_app_bundle.sh" "$APP_PATH" \
	|| fail "verify_app_bundle.sh failed for $APP_PATH"

echo "Release build check passed: $APP_PATH ($MARKETING_VERSION, build $BUILD_NUMBER) and its embedded yh are Developer ID signed, hardened, arm64-only, and unentitled for debugging."
