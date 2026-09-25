#!/usr/bin/env bash
# Derives the Release build's MARKETING_VERSION and CURRENT_PROJECT_VERSION from a git tag.
#
# Usage: release-version.sh <tag>
#
# The tag must match vX.Y.Z (no pre-release or build-metadata suffixes) and must already
# exist in this repository. MARKETING_VERSION is X.Y.Z. CURRENT_PROJECT_VERSION is the
# number of commits reachable from the tag (`git rev-list --count <tag>`): it is
# deterministic from the tag alone (unlike a CI run number) and, because commit count is
# monotonic along main's history, Sparkle's CFBundleVersion comparison never goes backwards
# for tags cut in order along main.
#
# Prints exactly two lines to stdout:
#   MARKETING_VERSION=X.Y.Z
#   CURRENT_PROJECT_VERSION=N
#
# When $GITHUB_ENV is set, both lines are also appended to it.
set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }

[ $# -eq 1 ] || fail "Usage: $0 <tag>"
tag="$1"

[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "tag '$tag' does not match vX.Y.Z"

git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "tag '$tag' does not exist in this repository"

marketing_version="${tag#v}"
build_number="$(git rev-list --count "refs/tags/$tag")"

echo "MARKETING_VERSION=$marketing_version"
echo "CURRENT_PROJECT_VERSION=$build_number"

if [ -n "${GITHUB_ENV:-}" ]; then
	{
		echo "MARKETING_VERSION=$marketing_version"
		echo "CURRENT_PROJECT_VERSION=$build_number"
	} >> "$GITHUB_ENV"
fi
