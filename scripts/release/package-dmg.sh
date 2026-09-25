#!/usr/bin/env bash
# Package a notarized, stapled .app into a signed, notarized, stapled disk image for
# distribution (roadmap P16.4). Used by release jobs after scripts/release/notarize.sh.
#
# The DMG itself is separately signed and notarized: Gatekeeper's assessment of a
# double-clicked disk image looks at the DMG's own signature, not just the app inside it.
#
# Auth: same convention as scripts/release/notarize.sh — if NOTARY_API_KEY_PATH is set
# (CI; written to $GITHUB_ENV by setup-signing.sh), NOTARY_API_KEY_ID and
# NOTARY_API_ISSUER_ID (secrets) must also be set, and notarytool authenticates with
# --key/--key-id/--issuer. Otherwise notarytool authenticates with the keychain profile
# named by NOTARY_PROFILE (default: yellowhammer-notary).
#
# Environment:
#   SIGNING_IDENTITY       codesign identity for the DMG (default: "Developer ID Application")
#   KEYCHAIN_PATH           optional; passed to codesign as --keychain
#   NOTARY_API_KEY_PATH     path to the .p8 API key (CI only; triggers --key auth)
#   NOTARY_API_KEY_ID       key ID of that API key (required with NOTARY_API_KEY_PATH)
#   NOTARY_API_ISSUER_ID    issuer ID of that API key (required with NOTARY_API_KEY_PATH)
#   NOTARY_PROFILE          notarytool keychain profile name (local only; default above)
#   NOTARY_TIMEOUT          notarytool --wait timeout (default: 30m)
#
# Writes into <out-dir>:
#   <name>.dmg                  the signed, notarized, stapled disk image
#   dmg-notarization-submit.json  full `notarytool submit --output-format json` output
#   dmg-notarization-log.json     full `notarytool log` output for the submission
#   SHA256SUMS                  checksums for the DMG and every extra file passed in,
#                                using bare file names so it verifies from the out dir
#
# Usage: package-dmg.sh <path-to-app> <out-dir> <dmg-basename> [extra-file-in-out-dir]...
set -euo pipefail

fail() {
	echo "::error title=Packaging::$1"
	exit 1
}

[ $# -ge 3 ] || fail "Usage: $0 <path-to-app> <out-dir> <dmg-basename> [extra-file-in-out-dir]..."

APP_PATH="$1"
OUT_DIR="$2"
DMG_BASENAME="$3"
shift 3
EXTRA_FILES=("$@")

[ -d "$APP_PATH" ] || fail "App bundle does not exist: $APP_PATH"
mkdir -p "$OUT_DIR"

if [ -n "${NOTARY_API_KEY_PATH:-}" ]; then
	[ -n "${NOTARY_API_KEY_ID:-}" ] || fail "NOTARY_API_KEY_ID is not set (required with NOTARY_API_KEY_PATH)"
	[ -n "${NOTARY_API_ISSUER_ID:-}" ] || fail "NOTARY_API_ISSUER_ID is not set (required with NOTARY_API_KEY_PATH)"
	notary_auth=(--key "$NOTARY_API_KEY_PATH" --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_API_ISSUER_ID")
else
	notary_auth=(--keychain-profile "${NOTARY_PROFILE:-yellowhammer-notary}")
fi

signing_identity="${SIGNING_IDENTITY:-Developer ID Application}"
codesign_args=(--force --sign "$signing_identity" --timestamp)
if [ -n "${KEYCHAIN_PATH:-}" ]; then
	codesign_args+=(--keychain "$KEYCHAIN_PATH")
fi

dmg_path="$OUT_DIR/${DMG_BASENAME}.dmg"

# --- Stage app + /Applications symlink, then build the DMG ---
stage_dir="$(mktemp -d)"
trap 'rm -rf "$stage_dir"' EXIT

ditto "$APP_PATH" "$stage_dir/$(basename "$APP_PATH")" \
	|| fail "could not copy $APP_PATH into staging directory"
ln -s /Applications "$stage_dir/Applications" \
	|| fail "could not create the /Applications symlink in staging directory"

rm -f "$dmg_path"
hdiutil create -volname Yellowhammer -srcfolder "$stage_dir" -format UDZO -fs APFS -ov "$dmg_path" \
	|| fail "hdiutil create failed for $dmg_path"

# --- Sign the DMG itself ---
codesign "${codesign_args[@]}" "$dmg_path" \
	|| fail "codesign failed for $dmg_path"

# --- Submit for notarization ---
submit_json="$OUT_DIR/dmg-notarization-submit.json"
notarytool_exit=0
xcrun notarytool submit "$dmg_path" "${notary_auth[@]}" \
	--wait --timeout "${NOTARY_TIMEOUT:-30m}" --output-format json > "$submit_json" \
	|| notarytool_exit=$?
[ -s "$submit_json" ] || fail "notarytool submit produced no output (exit $notarytool_exit) for $dmg_path"

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

log_json="$OUT_DIR/dmg-notarization-log.json"
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
	|| fail "DMG notarization status is '$submission_status' for submission $submission_id; see $log_json"

# --- Staple, then verify codesign / spctl (notarized, open context) / staple validity ---
xcrun stapler staple "$dmg_path" \
	|| fail "xcrun stapler staple failed for $dmg_path"

codesign --verify --strict --verbose=2 "$dmg_path" \
	|| fail "codesign --verify --strict failed for $dmg_path"

spctl_output=$(spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path" 2>&1) \
	|| fail "spctl --assess rejected $dmg_path: $spctl_output"
echo "$spctl_output"
echo "$spctl_output" | grep -q 'source=Notarized Developer ID' \
	|| fail "spctl did not report source=Notarized Developer ID for $dmg_path: $spctl_output"

stapler_output=$(xcrun stapler validate "$dmg_path" 2>&1) \
	|| fail "xcrun stapler validate failed for $dmg_path: $stapler_output"
echo "$stapler_output"

# --- Checksums, bare file names so `shasum -a 256 -c SHA256SUMS` works from the out dir ---
checksum_files=("$(basename "$dmg_path")")
for extra in ${EXTRA_FILES[@]+"${EXTRA_FILES[@]}"}; do
	[ -f "$extra" ] || fail "extra file for checksums does not exist: $extra"
	checksum_files+=("$(basename "$extra")")
done

(
	cd "$OUT_DIR" \
		|| exit 1
	shasum -a 256 "${checksum_files[@]}" > SHA256SUMS
) || fail "could not write SHA256SUMS in $OUT_DIR"

echo "Packaging passed: $dmg_path is signed, notarized (submission $submission_id), stapled, verified; checksums in $OUT_DIR/SHA256SUMS"
