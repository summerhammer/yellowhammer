#!/usr/bin/env bash
# Signs the notarized distributable zip with Sparkle's EdDSA private key and writes a
# single-item appcast.xml for the update channel (roadmap P16.5). Used by release jobs
# after scripts/release/package-dmg.sh; the appcast's enclosure points at the same zip
# already uploaded to the tag's GitHub release, so the release job must publish that zip
# under exactly the name this script is given.
#
# Only one item is ever written: the latest release. Sparkle is pointed at
# .../releases/latest/download/appcast.xml (see Support/Yellowhammer-Info.plist), so an
# older Mac that missed intermediate releases is offered only the newest one, not a chain
# of upgrades — a known limitation, not a bug (see doc/update-channel.md).
#
# The private key is never echoed, never passed as a CLI argument (which would appear in
# `ps`), and never written to disk: it is piped to `sign_update --ed-key-file -` on stdin.
#
# Environment:
#   SPARKLE_ED_PRIVATE_KEY   required; the base64 EdDSA private key from
#                            `generate_keys -x` (secret; CI: secrets.SPARKLE_ED_PRIVATE_KEY)
#   SIGN_UPDATE_PATH         path to Sparkle's `sign_update` tool; default is where
#                            `xcodebuild -clonedSourcePackagesDirPath build/SourcePackages`
#                            resolves the Sparkle package's binary artifacts
#
# Usage: appcast.sh <path-to-zip> <marketing-version> <build-number> <tag> <out-dir>
#
# Writes <out-dir>/appcast.xml, whose enclosure url is:
#   https://github.com/summerhammer/yellowhammer/releases/download/<tag>/<zip-name>
set -euo pipefail

fail() {
	echo "::error title=Appcast::$1"
	exit 1
}

[ $# -eq 5 ] || fail "Usage: $0 <path-to-zip> <marketing-version> <build-number> <tag> <out-dir>"

ZIP_PATH="$1"
MARKETING_VERSION="$2"
BUILD_NUMBER="$3"
TAG="$4"
OUT_DIR="$5"

[ -f "$ZIP_PATH" ] || fail "Zip does not exist: $ZIP_PATH"
[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ] || fail "SPARKLE_ED_PRIVATE_KEY is not set"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

sign_update_path="${SIGN_UPDATE_PATH:-$REPO_ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update}"
[ -x "$sign_update_path" ] || fail "sign_update not found or not executable at $sign_update_path (set SIGN_UPDATE_PATH to override)"

mkdir -p "$OUT_DIR"

zip_name="$(basename "$ZIP_PATH")"
zip_length="$(wc -c < "$ZIP_PATH" | tr -d ' ')" \
	|| fail "could not determine the size of $ZIP_PATH"

# --- Sign: the key is piped on stdin, never a CLI argument or an on-disk file ---
signature="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$sign_update_path" --ed-key-file - -p "$ZIP_PATH")" \
	|| fail "sign_update failed to sign $ZIP_PATH"
[ -n "$signature" ] || fail "sign_update produced no signature for $ZIP_PATH"

enclosure_url="https://github.com/summerhammer/yellowhammer/releases/download/${TAG}/${zip_name}"
pub_date="$(LC_ALL=C date -u +"%a, %d %b %Y %H:%M:%S +0000")"

appcast_path="$OUT_DIR/appcast.xml"
cat > "$appcast_path" <<XML
<?xml version="1.0" standalone="yes"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
	<channel>
		<title>Yellowhammer</title>
		<link>https://github.com/summerhammer/yellowhammer/releases/latest/download/appcast.xml</link>
		<description>Yellowhammer update channel.</description>
		<language>en</language>
		<item>
			<title>Yellowhammer ${MARKETING_VERSION}</title>
			<pubDate>${pub_date}</pubDate>
			<sparkle:version>${BUILD_NUMBER}</sparkle:version>
			<sparkle:shortVersionString>${MARKETING_VERSION}</sparkle:shortVersionString>
			<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
			<enclosure
				url="${enclosure_url}"
				length="${zip_length}"
				type="application/octet-stream"
				sparkle:edSignature="${signature}" />
		</item>
	</channel>
</rss>
XML

echo "Appcast written: $appcast_path (version $MARKETING_VERSION, build $BUILD_NUMBER, enclosure $enclosure_url)"
