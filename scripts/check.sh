#!/bin/sh
# The engine-run Check for this repository: `check = "scripts/check.sh"` in the Project's TOML.
#
# The engine keeps only the last 64 KiB of a Check's output (WorktreeCheck.defaultOutputLimit). A
# whole-package `swift test` prints about 1.4 MB of started/passed lines, and a failure printed mid-run
# never reaches that tail, so the next Round's brief said only "Some test targets reported failures".
# This runs the same tests, keeps the full log, and prints the summaries and then the failures last,
# inside the kept tail.
#
# The verdict is `swift test`'s own exit status: nothing is retried or filtered. Extra arguments are
# passed to `swift test` (e.g. `scripts/check.sh --filter EngineCommandTests`).
set -u

repo=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
log_dir=${TMPDIR:-/tmp}
log="${log_dir%/}/yh-check-$(date -u +%Y%m%dT%H%M%SZ)-$$.log"

swift test --package-path "$repo/Packages/YellowhammerKit" "$@" >"$log" 2>&1
status=$?

# Lines are cut to 400 bytes and the sections capped, so everything below fits in the engine's 64 KiB.
grep -E 'Test run with|test targets reported failures|^  - ' "$log" | cut -c1-400 | tail -n 40
if [ "$status" -ne 0 ]; then
    printf '\n── failures (full log: %s) ──\n' "$log"
    # Swift Testing: each recorded issue with its detail lines, and each failed test's and suite's
    # verdict. Parallel tests interleave, so other tests' started/passed lines are dropped from the context.
    grep -E -A2 'recorded an issue|failed after' "$log" | grep -v -E '(started|passed after [0-9.]+ seconds)\.$' \
        | cut -c1-400 | head -n 150
    # A build error, a crash, or a test process killed by a signal names no test.
    grep -E 'error: |Fatal error|fatal error|unexpected signal|crashed' "$log" | grep -v 'Test "' \
        | cut -c1-400 | head -n 30
fi
printf '\nswift test exited %s; full log: %s\n' "$status" "$log"
exit "$status"
