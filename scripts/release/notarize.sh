#!/usr/bin/env bash
# Submit a signed Release .app to Apple's notary service, staple the resulting ticket,
# verify the result, and produce the notarized distributable zip. Used by release jobs
# after scripts/release/verify-release-build.sh. Packaging (DMG, checksums, hosting) is
# P16.4 — this script stops at a notarized, stapled, verified .app and its zip.
#
# Auth: if NOTARY_API_KEY_PATH is set (CI; written to $GITHUB_ENV by setup-signing.sh),
# NOTARY_API_KEY_ID and NOTARY_API_ISSUER_ID (secrets) must also be set, and notarytool
# authenticates with --key/--key-id/--issuer. Otherwise notarytool authenticates with the
# keychain profile named by NOTARY_PROFILE (default: yellowhammer-notary) — see
# scripts/release/setup-signing.sh --verify-only for provisioning that profile locally.
#
# Environment:
#   NOTARY_API_KEY_PATH    path to the .p8 API key (CI only; triggers --key auth)
#   NOTARY_API_KEY_ID      key ID of that API key (required with NOTARY_API_KEY_PATH)
#   NOTARY_API_ISSUER_ID   issuer ID of that API key (required with NOTARY_API_KEY_PATH)
#   NOTARY_PROFILE         notarytool keychain profile name (local only; default above)
#   NOTARY_TIMEOUT         notarytool --wait timeout (default: 30m)
#   NOTARIZED_ZIP_NAME     name of the final distributable zip (default: <AppName>.zip)
#
# Writes into <output-dir>:
#   <AppName>-submission.zip   the pre-notarization upload (no ticket — not for distribution)
#   notarization-submit.json   full `notarytool submit --output-format json` output
#   notarization-log.json      full `notarytool log` output for the submission
#   <zip-name>                 the stapled, verified app, re-zipped for distribution
#
# Usage: notarize.sh <path-to-app> <output-dir>
set -euo pipefail

fail() {
	echo "::error title=Notarization::$1"
	exit 1
}

[ $# -eq 2 ] || fail "Usage: $0 <path-to-app> <output-dir>"

APP_PATH="$1"
OUT_DIR="$2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -d "$APP_PATH" ] || fail "App bundle does not exist: $APP_PATH"
mkdir -p "$OUT_DIR"

if [ -n "${NOTARY_API_KEY_PATH:-}" ]; then
	[ -n "${NOTARY_API_KEY_ID:-}" ] || fail "NOTARY_API_KEY_ID is not set (required with NOTARY_API_KEY_PATH)"
	[ -n "${NOTARY_API_ISSUER_ID:-}" ] || fail "NOTARY_API_ISSUER_ID is not set (required with NOTARY_API_KEY_PATH)"
	notary_auth=(--key "$NOTARY_API_KEY_PATH" --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_API_ISSUER_ID")
else
	notary_auth=(--keychain-profile "${NOTARY_PROFILE:-yellowhammer-notary}")
fi

app_name="$(basename "$APP_PATH" .app)"

# --- Submit ---
submission_zip="$OUT_DIR/${app_name}-submission.zip"
ditto -c -k --keepParent "$APP_PATH" "$submission_zip" \
	|| fail "ditto could not create the submission zip from $APP_PATH"

submit_json="$OUT_DIR/notarization-submit.json"
# Do not let a non-Accepted (or timed-out) `notarytool submit` exit code short-circuit us
# before we've parsed its JSON and fetched the log: the JSON is the source of truth.
notarytool_exit=0
xcrun notarytool submit "$submission_zip" "${notary_auth[@]}" \
	--wait --timeout "${NOTARY_TIMEOUT:-30m}" --output-format json > "$submit_json" \
	|| notarytool_exit=$?
[ -s "$submit_json" ] || fail "notarytool submit produced no output (exit $notarytool_exit); see $submission_zip"

json_field() {
	python3 - "$1" "$2" <<'PY'
import json
import sys

path, field = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    print("")
    sys.exit(0)
value = data.get(field)
print(value if value is not None else "")
PY
}

submission_id="$(json_field "$submit_json" id)"
submission_status="$(json_field "$submit_json" status)"
[ -n "$submission_id" ] || fail "could not parse a submission id from $submit_json (notarytool exit $notarytool_exit)"

# --- Fetch the log unconditionally, before deciding pass/fail ---
log_json="$OUT_DIR/notarization-log.json"
if ! xcrun notarytool log "$submission_id" "${notary_auth[@]}" "$log_json"; then
	echo "warning: could not fetch notarization log for submission $submission_id" >&2
fi

if [ -s "$log_json" ]; then
	python3 - "$log_json" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
issues = data.get("issues")
if issues:
    print("Notarization issues:")
    for issue in issues:
        print(f"  - {issue}")
PY
fi

[ "$submission_status" = "Accepted" ] \
	|| fail "notarization status is '$submission_status' for submission $submission_id; see $log_json"

# --- Staple, then verify codesign / spctl (notarized) / staple validity ---
xcrun stapler staple "$APP_PATH" \
	|| fail "xcrun stapler staple failed for $APP_PATH"

"$SCRIPT_DIR/verify-notarized.sh" "$APP_PATH" \
	|| fail "verify-notarized.sh failed for $APP_PATH"

# --- Re-zip the stapled, verified app as the distributable ---
zip_name="${NOTARIZED_ZIP_NAME:-${app_name}.zip}"
final_zip="$OUT_DIR/$zip_name"
ditto -c -k --keepParent "$APP_PATH" "$final_zip" \
	|| fail "ditto could not create the notarized distributable zip from $APP_PATH"

echo "Notarization passed: $APP_PATH is notarized (submission $submission_id), stapled, verified, and zipped to $final_zip"
