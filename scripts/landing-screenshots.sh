#!/bin/bash
# Captures the landing page's app screenshots (S1, S2, S4 of the web repo's astro/SCREENSHOTS.md) from stub
# Journals, in light and dark, with the standalone tool in Tools/LandingScreenshots.
#
#   scripts/landing-screenshots.sh [output-dir]
#
# The output defaults to ../yellowhammer-artwork/screenshots/landing beside the main checkout. Run it on a
# Retina display, logged in, between 06:00 and 22:00 local (the example Night is 22:00–06:00). The terminal needs
# the Screen Recording permission and Automation for System Events, each granted once. Set YH_DERIVED_DATA
# to reuse a build.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
main_checkout="$(dirname "$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)")"
output="${1:-$main_checkout/../yellowhammer-artwork/screenshots/landing}"
derived="${YH_DERIVED_DATA:-$(mktemp -d "${TMPDIR:-/tmp}/yh-landing-shots.XXXXXX")/DerivedData}"

echo "==> Building the Debug app"
xcodebuild build -quiet \
    -project "$repo/Yellowhammer.xcodeproj" -scheme Yellowhammer -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$derived"

echo "==> Capturing"
swift run --package-path "$repo/Tools/LandingScreenshots" landing-screenshots \
    --app "$derived/Build/Products/Debug/Yellowhammer.app" --output "$output" "${@:2}"
echo "==> Wrote the screenshots to $output"
