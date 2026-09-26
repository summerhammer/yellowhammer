#!/usr/bin/env bash
# Derives release notes for a tag from the `Spec: <epic>/<story> @ <sha>` trailer lines
# carried by every commit implementing spec'd behavior (see CLAUDE.md). Used by release
# jobs after scripts/release/package-dmg.sh. Prints Markdown to stdout.
#
# Usage: release-notes.sh <tag> [<previous-tag>]
#
# <previous-tag> defaults to the most recent `v*` tag reachable from <tag>^ (i.e. an
# earlier point in history than <tag> itself); if there is none, the range is from the
# root commit. The notes cover every commit in <previous-tag>..<tag> (or the whole
# history up to <tag> when there is no previous tag).
set -euo pipefail

fail() { echo "error: $*" >&2; exit 1; }

if [ $# -lt 1 ] || [ $# -gt 2 ]; then fail "Usage: $0 <tag> [<previous-tag>]"; fi

tag="$1"
previous_tag="${2:-}"

git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "tag '$tag' does not exist in this repository"

if [ -z "$previous_tag" ]; then
	previous_tag="$(git describe --tags --abbrev=0 --match 'v*' "${tag}^" 2>/dev/null || true)"
fi

if [ -n "$previous_tag" ]; then
	git rev-parse -q --verify "refs/tags/$previous_tag" >/dev/null \
		|| fail "previous tag '$previous_tag' does not exist in this repository"
	range="$previous_tag..$tag"
else
	range="$tag"
fi

# Newest-first commit log (git log's default order), so the first `Spec:` trailer line
# we see, in order, is the newest one.
spec_lines=()
newest_sha=""
while IFS= read -r line; do
	[ -n "$line" ] || continue
	spec_lines+=("$line")
done < <(git log --format=%B "$range" | grep '^Spec: ' || true)

if [ "${#spec_lines[@]}" -gt 0 ]; then
	# First match in commit order (newest-first, since git log defaults newest-first) is
	# the newest cited spec commit.
	newest_line="${spec_lines[0]}"
	newest_sha="$(printf '%s' "$newest_line" | sed -nE 's/^Spec: [^ ]+ @ ([0-9a-fA-F]+)$/\1/p')"
fi

story_ids=()
spec_shas=()
for line in ${spec_lines[@]+"${spec_lines[@]}"}; do
	story="$(printf '%s' "$line" | sed -nE 's/^Spec: ([^ ]+) @ [0-9a-fA-F]+$/\1/p')"
	sha="$(printf '%s' "$line" | sed -nE 's/^Spec: [^ ]+ @ ([0-9a-fA-F]+)$/\1/p')"
	[ -n "$story" ] || continue
	story_ids+=("$story")
	[ -n "$sha" ] && spec_shas+=("$sha")
done

unique_sorted() {
	if [ "$#" -eq 0 ]; then
		return 0
	fi
	printf '%s\n' "$@" | sort -u
}

echo "# Yellowhammer $tag"
echo
if [ -n "$newest_sha" ]; then
	echo "Built against spec commit $newest_sha."
else
	echo "Built against spec commit: none cited."
fi
echo

if [ "${#story_ids[@]}" -gt 0 ]; then
	echo "## Stories"
	echo
	while IFS= read -r story; do
		[ -n "$story" ] || continue
		echo "- $story"
	done < <(unique_sorted ${story_ids[@]+"${story_ids[@]}"})
	echo
fi

unique_shas="$(unique_sorted ${spec_shas[@]+"${spec_shas[@]}"})"
sha_count="$(printf '%s\n' "$unique_shas" | grep -c . || true)"
if [ "$sha_count" -gt 1 ]; then
	echo "## Spec commits cited"
	echo
	while IFS= read -r sha; do
		[ -n "$sha" ] || continue
		echo "- $sha"
	done < <(printf '%s\n' "$unique_shas")
	echo
fi

echo "## Verify the download"
echo
echo "Run \`shasum -a 256 -c SHA256SUMS\` in the folder with the downloaded files to"
echo "confirm the DMG and zip match what was published."
