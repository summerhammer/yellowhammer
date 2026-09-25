#!/usr/bin/env bash
# Installs the Developer ID Application identity and the notarization credential into a
# temporary keychain, then proves both work without manual input. Used by release jobs.
#
# Usage: setup-signing.sh [--verify-only]
#
# Environment (CI secrets; see doc/signing-identity.md):
#   DEVELOPER_ID_P12_BASE64   base64 of the exported .p12 (certificate + private key)
#   DEVELOPER_ID_P12_PASSWORD password of that .p12
#   NOTARY_API_KEY_BASE64     base64 of the App Store Connect API key (.p8)
#   NOTARY_API_KEY_ID         key ID of that API key
#   NOTARY_API_ISSUER_ID      issuer ID of the App Store Connect team
#   DEVELOPER_TEAM_ID         optional; picks the identity of this team when several exist
#   KEYCHAIN_PATH             optional; defaults to $RUNNER_TEMP/yellowhammer-release.keychain-db
#
# --verify-only skips the import and checks the release machine's own keychain, using the
# notarytool keychain profile named by NOTARY_PROFILE (default: yellowhammer-notary).
#
# Writes SIGNING_IDENTITY and KEYCHAIN_PATH to $GITHUB_ENV when that file exists.
set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }

verify_only=0
case "${1:-}" in
	--verify-only) verify_only=1 ;;
	"") ;;
	*) fail "unknown argument: $1" ;;
esac

tmp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
keychain_args=()

if [ "$verify_only" -eq 0 ]; then
	for var in DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD NOTARY_API_KEY_BASE64 \
		NOTARY_API_KEY_ID NOTARY_API_ISSUER_ID; do
		[ -n "${!var:-}" ] || fail "$var is not set"
	done

	keychain="${KEYCHAIN_PATH:-$tmp/yellowhammer-release.keychain-db}"
	keychain_password="$(uuidgen)"
	p12="$tmp/developer-id.p12"
	api_key="$tmp/AuthKey_${NOTARY_API_KEY_ID}.p8"
	trap 'rm -f "$p12"' EXIT

	printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 --decode > "$p12"
	printf '%s' "$NOTARY_API_KEY_BASE64" | base64 --decode > "$api_key"
	chmod 600 "$api_key"

	security create-keychain -p "$keychain_password" "$keychain"
	security set-keychain-settings -lut 21600 "$keychain"
	security unlock-keychain -p "$keychain_password" "$keychain"
	security import "$p12" -k "$keychain" -P "$DEVELOPER_ID_P12_PASSWORD" \
		-T /usr/bin/codesign -T /usr/bin/security
	# Lets codesign use the key without a GUI prompt.
	security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" >/dev/null
	# Put the keychain in the search list so xcodebuild and codesign find the identity.
	existing=$(security list-keychains -d user | tr -d '"')
	# shellcheck disable=SC2086
	security list-keychains -d user -s "$keychain" $existing
	keychain_args=(--keychain "$keychain")
	notary_auth=(--key "$api_key" --key-id "$NOTARY_API_KEY_ID" --issuer "$NOTARY_API_ISSUER_ID")
else
	keychain="${KEYCHAIN_PATH:-}"
	if [ -n "$keychain" ]; then keychain_args=(--keychain "$keychain"); fi
	notary_auth=(--keychain-profile "${NOTARY_PROFILE:-yellowhammer-notary}")
fi

identity=$(security find-identity -v -p codesigning ${keychain:+"$keychain"} \
	| sed -nE 's/^ *[0-9]+\) [0-9A-F]+ "(Developer ID Application: [^"]+)"$/\1/p' \
	| grep -F "${DEVELOPER_TEAM_ID:+(${DEVELOPER_TEAM_ID})}" | head -1 || true)
[ -n "$identity" ] || fail "no valid Developer ID Application identity found"
echo "Signing identity: $identity"

# Prove the identity signs non-interactively, with hardened runtime and a secure timestamp.
probe="$tmp/yellowhammer-signing-probe"
cp /usr/bin/true "$probe"
codesign --force --options runtime --timestamp --sign "$identity" ${keychain_args[@]+"${keychain_args[@]}"} "$probe"
codesign --verify --strict "$probe"
rm -f "$probe"
echo "Signing: ok"

# Prove the notarization credential authenticates, without submitting anything.
xcrun notarytool history "${notary_auth[@]}" --output-format json >/dev/null \
	|| fail "notarytool could not authenticate"
echo "Notarization credential: ok"

if [ -n "${GITHUB_ENV:-}" ]; then
	{
		echo "SIGNING_IDENTITY=$identity"
		if [ -n "$keychain" ]; then echo "KEYCHAIN_PATH=$keychain"; fi
		if [ "$verify_only" -eq 0 ]; then echo "NOTARY_API_KEY_PATH=$api_key"; fi
	} >> "$GITHUB_ENV"
fi
