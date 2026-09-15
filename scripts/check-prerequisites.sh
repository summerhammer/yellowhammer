#!/bin/bash
#
# check-prerequisites.sh — Validate Yellowhammer developer workstation prerequisites.
#
# Usage: check-prerequisites.sh [--with-signing] [--with-linear] [--help]
#
# Flags:
#   --with-signing   Also check for Developer ID Application signing identity
#   --with-linear    Also check for Linear workspace access (not checkable yet)
#   --help           Show this help message
#
# Exit codes:
#   0 — All checks passed
#   1 — At least one FAIL check

set -u

# Minimum versions
MIN_XCODE_MAJOR=26
REQUIRED_XCODE_MAJOR=26
REQUIRED_XCODE_MINOR=6
REQUIRED_SWIFTLINT_VERSION="0.65.0"
MIN_ORCA_VERSION="1.4.195"

# State tracking
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
WITH_SIGNING=0
WITH_LINEAR=0

# Colors (only when stdout is a TTY)
if [ -t 1 ]; then
	GREEN='\033[0;32m'
	YELLOW='\033[0;33m'
	RED='\033[0;31m'
	GRAY='\033[0;90m'
	NC='\033[0m'
else
	GREEN=''
	YELLOW=''
	RED=''
	GRAY=''
	NC=''
fi

# Parse flags
while [ $# -gt 0 ]; do
	case "$1" in
		--with-signing)
			WITH_SIGNING=1
			shift
			;;
		--with-linear)
			WITH_LINEAR=1
			shift
			;;
		--help)
			sed -n '2,14p' "$0" | sed 's/^# //'
			exit 0
			;;
		*)
			echo "Unknown flag: $1" >&2
			exit 1
			;;
	esac
done

# Helper: Version comparison
# Returns 0 if $1 >= $2
compare_versions() {
	local v1="$1"
	local v2="$2"

	# Split versions into components (bash 3.2 compatible)
	# shellcheck disable=SC2206
	local IFS='.'
	# shellcheck disable=SC2206
	local v1_parts=($v1)
	# shellcheck disable=SC2206
	local v2_parts=($v2)
	local IFS=' '

	# Compare each component
	local i=0
	while [ $i -lt ${#v1_parts[@]} ] || [ $i -lt ${#v2_parts[@]} ]; do
		local part1="${v1_parts[$i]:-0}"
		local part2="${v2_parts[$i]:-0}"

		# Convert to numbers for comparison
		part1=$((part1 + 0))
		part2=$((part2 + 0))

		if [ $part1 -gt $part2 ]; then
			return 0
		elif [ $part1 -lt $part2 ]; then
			return 1
		fi
		i=$((i + 1))
	done
	return 0
}

# Helper: Report check result
report() {
	local status="$1"
	local name="$2"
	local detail="$3"

	local color=""
	case "$status" in
		PASS) color="$GREEN"; PASS_COUNT=$((PASS_COUNT + 1)) ;;
		WARN) color="$YELLOW"; WARN_COUNT=$((WARN_COUNT + 1)) ;;
		FAIL) color="$RED"; FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
		SKIP) color="$GRAY"; SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
	esac

	printf "%b%-5s%b  %s  — %s\n" "$color" "$status" "$NC" "$name" "$detail"
}

# Helper: Run a command with a timeout in seconds. Stock macOS has no `timeout`; perl's alarm works.
with_timeout() {
	local seconds="$1"
	shift
	perl -e 'alarm shift; exec @ARGV or exit 127' "$seconds" "$@"
}

# Helper: Check if a command exists on PATH
has_command() {
	command -v "$1" >/dev/null 2>&1
}

# Check: Apple Silicon (arm64)
check_architecture() {
	local arch
	arch=$(uname -m)
	if [ "$arch" = "arm64" ]; then
		report PASS "Apple Silicon (arm64)" "Running on $arch"
	else
		report FAIL "Apple Silicon (arm64)" "Running on $arch, but Apple Silicon is required"
	fi
}

# Check: Xcode
check_xcode() {
	if ! has_command xcodebuild; then
		report FAIL "Xcode" "Not found; required for app build"
		return
	fi

	local xcode_version
	xcode_version=$(with_timeout 10 xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}')

	if [ -z "$xcode_version" ]; then
		report FAIL "Xcode" "Cannot determine version"
		return
	fi

	# Parse major.minor
	local xcode_major=${xcode_version%%.*}
	local xcode_minor=${xcode_version#*.}
	xcode_minor=${xcode_minor%%.*}

	if [ -z "$xcode_major" ] || [ -z "$xcode_minor" ]; then
		report FAIL "Xcode" "Cannot parse version: $xcode_version"
		return
	fi

	if [ "$xcode_major" -lt "$MIN_XCODE_MAJOR" ]; then
		report FAIL "Xcode $REQUIRED_XCODE_MAJOR.$REQUIRED_XCODE_MINOR" "Found $xcode_version; minimum is $MIN_XCODE_MAJOR.x"
	elif [ "$xcode_major" -eq "$REQUIRED_XCODE_MAJOR" ] && [ "$xcode_minor" -ne "$REQUIRED_XCODE_MINOR" ]; then
		report WARN "Xcode $REQUIRED_XCODE_MAJOR.$REQUIRED_XCODE_MINOR" "Found $xcode_version (CI pins $REQUIRED_XCODE_MAJOR.$REQUIRED_XCODE_MINOR)"
	elif [ "$xcode_major" -eq "$REQUIRED_XCODE_MAJOR" ] && [ "$xcode_minor" -eq "$REQUIRED_XCODE_MINOR" ]; then
		report PASS "Xcode $REQUIRED_XCODE_MAJOR.$REQUIRED_XCODE_MINOR" "Installed ($xcode_version)"
	else
		report WARN "Xcode $REQUIRED_XCODE_MAJOR.$REQUIRED_XCODE_MINOR" "Found $xcode_version (newer than CI pin)"
	fi
}

# Check: SwiftLint
check_swiftlint() {
	if ! has_command swiftlint; then
		report FAIL "SwiftLint" "Not found; required for linting"
		return
	fi

	local sl_version
	sl_version=$(with_timeout 10 swiftlint --version 2>/dev/null)

	if [ "$sl_version" = "$REQUIRED_SWIFTLINT_VERSION" ]; then
		report PASS "SwiftLint $REQUIRED_SWIFTLINT_VERSION" "Installed ($sl_version)"
	else
		report WARN "SwiftLint $REQUIRED_SWIFTLINT_VERSION" "Found $sl_version (CI pins $REQUIRED_SWIFTLINT_VERSION)"
	fi
}

# Check: Orca ADE
check_orca() {
	if ! has_command orca; then
		# Also try detecting via /Applications
		if [ ! -d "/Applications/Orca.app" ]; then
			report FAIL "Orca ADE (≥$MIN_ORCA_VERSION)" "Not found; required prerequisite"
			return
		fi
		# Try to get version from Info.plist
		local plist_version
		plist_version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "/Applications/Orca.app/Contents/Info.plist" 2>/dev/null)
		if [ -z "$plist_version" ]; then
			report WARN "Orca ADE (≥$MIN_ORCA_VERSION)" "Found at /Applications/Orca.app but cannot verify version"
			return
		fi
	else
		local plist_version
		plist_version=$(with_timeout 10 orca --version 2>/dev/null)
	fi

	if compare_versions "$plist_version" "$MIN_ORCA_VERSION"; then
		report PASS "Orca ADE (≥$MIN_ORCA_VERSION)" "Installed ($plist_version)"
	else
		report FAIL "Orca ADE (≥$MIN_ORCA_VERSION)" "Found $plist_version; minimum is $MIN_ORCA_VERSION"
	fi
}

# Check: Agent CLIs (at least one must be installed and authenticated)
check_agent_clis() {
	local found_authenticated=0
	local details=""

	# Check claude
	if has_command claude; then
		if with_timeout 5 claude auth status >/dev/null 2>&1; then
			found_authenticated=1
			details="claude (authenticated)"
		else
			details="claude (installed; auth not verifiable)"
		fi
	fi

	# Check codex
	if has_command codex; then
		if with_timeout 5 codex login status >/dev/null 2>&1; then
			found_authenticated=1
			if [ -z "$details" ]; then
				details="codex (authenticated)"
			else
				details="$details, codex (authenticated)"
			fi
		else
			if [ -z "$details" ]; then
				details="codex (installed; auth not verifiable)"
			else
				details="$details, codex (installed; auth not verifiable)"
			fi
		fi
	fi

	if [ -z "$details" ]; then
		report FAIL "Agent CLI (≥1 installed + authenticated)" "No CLIs found; at least one (claude or codex) is required"
		return
	fi

	if [ $found_authenticated -eq 1 ]; then
		report PASS "Agent CLI (≥1 installed + authenticated)" "$details"
	else
		report WARN "Agent CLI (≥1 installed + authenticated)" "$details"
	fi
}

# Check: git
check_git() {
	if env -i /bin/sh -c 'command -v git' >/dev/null 2>&1; then
		report PASS "git" "Available on PATH"
	else
		report FAIL "git" "Not found on PATH in bare environment"
	fi
}

# Check: Developer ID signing identity (optional)
check_developer_id() {
	if [ $WITH_SIGNING -eq 0 ]; then
		report SKIP "Developer ID signing" "Not requested (use --with-signing)"
		return
	fi

	if ! has_command security; then
		report FAIL "Developer ID signing" "security command not available"
		return
	fi

	# Look for Developer ID Application identities
	local dev_id_found=0
	local dev_ids=""

	# Bounded so a locked keychain cannot hang the check
	if with_timeout 10 security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
		dev_id_found=1
		dev_ids=$(with_timeout 10 security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/^[^"]*"([^"]*)".*$/\1/')
	fi

	if [ $dev_id_found -eq 1 ]; then
		report PASS "Developer ID signing" "Found: $dev_ids"
	else
		report FAIL "Developer ID signing" "No Developer ID Application identity found; needed for app signing"
	fi
}

# Check: Linear workspace access (optional)
check_linear() {
	if [ $WITH_LINEAR -eq 0 ]; then
		report SKIP "Linear workspace access" "Not requested (use --with-linear)"
		return
	fi

	# Linear board identity's keychain token reference arrives in a later step
	report SKIP "Linear workspace access" "Not checkable at this stage; credential validation occurs during setup (P5.1/P15.1)"
}

# Main
echo "Checking Yellowhammer prerequisites..."
echo ""

check_architecture
check_xcode
check_swiftlint
check_orca
check_agent_clis
check_git
check_developer_id
check_linear

# Summary
echo ""
echo "Summary:"
echo "  PASS: $PASS_COUNT"
echo "  WARN: $WARN_COUNT"
echo "  FAIL: $FAIL_COUNT"
echo "  SKIP: $SKIP_COUNT"

if [ $FAIL_COUNT -gt 0 ]; then
	exit 1
else
	exit 0
fi
