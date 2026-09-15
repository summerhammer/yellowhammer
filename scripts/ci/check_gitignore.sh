#!/bin/bash
set -euo pipefail

# Repo root (optional argument, defaults to current directory)
REPO_ROOT="${1:-.}"
cd "$REPO_ROOT"

FAILED=0

# Part A: Check that representative sample paths MUST be ignored
echo "=== Part A: Checking paths that MUST be ignored ==="
MUST_IGNORE=(
  ".env"
  "signing/dev.p12"
  "AuthKey_ABC.p8"
  "journals/acme.db"
  "acme.db-wal"
  "ledger.sqlite"
  "config.toml"
  "projects/acme.toml"
  "foo.local.toml"
  "scratch/fixture.json"
  "build/DerivedData/x"
)

for path in "${MUST_IGNORE[@]}"; do
  if git check-ignore -q --no-index "$path" 2>/dev/null; then
    echo "✓ $path is ignored"
  else
    echo "::error title=.gitignore audit::$path is not ignored"
    FAILED=1
  fi
done

# Part B: Check that representative paths MUST NOT be ignored
echo ""
echo "=== Part B: Checking paths that MUST NOT be ignored ==="
MUST_NOT_IGNORE=(
  ".env.example"
  ".swiftlint.yml"
  "Packages/YellowhammerKit/Package.resolved"
  ".codex/config.toml"
  "Packages/YellowhammerKit/Tests/Fixtures/project.toml"
)

for path in "${MUST_NOT_IGNORE[@]}"; do
  if git check-ignore -q --no-index "$path" 2>/dev/null; then
    echo "::error title=.gitignore audit::$path is ignored but should be tracked"
    FAILED=1
  else
    echo "✓ $path is not ignored"
  fi
done

# Part C: Check that no tracked files match the ignore rules
echo ""
echo "=== Part C: Checking for tracked files that match ignore rules ==="
TRACKED_IGNORED=$(git ls-files -ci --exclude-standard || true)
if [ -z "$TRACKED_IGNORED" ]; then
  echo "✓ No tracked files match ignore rules"
else
  echo "::error title=.gitignore audit::The following tracked files match ignore rules:"
  echo "$TRACKED_IGNORED" | while read -r file; do
    echo "::error title=.gitignore audit::  $file"
  done
  FAILED=1
fi

# Final result
echo ""
if [ $FAILED -eq 0 ]; then
  echo "✓ PASS: .gitignore audit successful"
  exit 0
else
  echo "✗ FAIL: .gitignore audit failed"
  exit 1
fi
