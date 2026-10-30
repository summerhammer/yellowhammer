#!/bin/sh
# Reproduction for yellowhammer#708, investigation step 2 (feeds spec OQ198).
#
# Builds disposable local git repositories under $WORK: a producer `lib` and a
# consumer `app`, one Feature Branch `feature/yh-1` per Repo, in the Worktree
# layout (Worktrees are siblings, so `../lib` from `app` is lib's checkout).
# Every Check is `./check.sh` run in the repository's own directory.
#
# Usage:  WORK=/some/empty/dir sh reproduce.sh
# No network, no installs. Needs sh, git, python3 and BSD (macOS) sed. Commit shas are
# deterministic (fixed names, emails and dates; no user git config).

set -u

: "${WORK:?set WORK to an empty or absent directory}"
if [ -e "$WORK" ] && [ -n "$(ls -A "$WORK")" ]; then
  echo "refusing: $WORK is not empty" >&2
  exit 1
fi
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd -P)

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Repro GIT_AUTHOR_EMAIL=repro@example.invalid
export GIT_COMMITTER_NAME=Repro GIT_COMMITTER_EMAIL=repro@example.invalid
TICK=1700000000

commit() { # dir message
  TICK=$((TICK + 60))
  GIT_AUTHOR_DATE="@$TICK +0000" GIT_COMMITTER_DATE="@$TICK +0000" \
    git -C "$1" -c commit.gpgsign=false commit -q -m "$2"
  echo "commit $(git -C "$1" rev-parse --short HEAD) in ${1#"$WORK"/}: $2"
}

merge() { # dir branch message  (no-ff merge into the checked-out branch)
  TICK=$((TICK + 60))
  GIT_AUTHOR_DATE="@$TICK +0000" GIT_COMMITTER_DATE="@$TICK +0000" \
    git -C "$1" -c commit.gpgsign=false merge -q --no-ff -m "$3" "$2"
  echo "merge  $(git -C "$1" rev-parse --short HEAD) in ${1#"$WORK"/}: $3"
}

run_check() { # dir
  echo "\$ cd \$WORK/${1#"$WORK"/} && ./check.sh    # HEAD $(git -C "$1" rev-parse --short HEAD) ($(git -C "$1" rev-parse --abbrev-ref HEAD))"
  out=$(cd "$1" && ./check.sh 2>&1); st=$?
  printf '%s\n' "$out" | sed 's/^/  | /'
  echo "  exit status: $st"
}

# --- file writers ---------------------------------------------------------

write_lib_A0() { # dir
  cat > "$1/lib.py" <<'EOF'
def greet(name):
    return "Hello, " + name
EOF
  cat > "$1/test_lib.py" <<'EOF'
from lib import greet
assert greet("x") == "Hello, x"
print("lib tests passed")
EOF
  cat > "$1/check.sh" <<'EOF'
#!/bin/sh
python3 -B test_lib.py
EOF
  chmod +x "$1/check.sh"
}

write_app_check_path() { # dir   consumer resolves the producer as the sibling directory
  cat > "$1/check.sh" <<'EOF'
#!/bin/sh
echo "check: lib resolved from ../lib at $(git -C ../lib rev-parse --short HEAD)"
PYTHONPATH=../lib python3 -B test_app.py
EOF
  chmod +x "$1/check.sh"
}

write_app_check_pin() { # dir   consumer resolves the producer at the commit in lib.lock
  cat > "$1/check.sh" <<'EOF'
#!/bin/sh
pin=${LIB_PIN_OVERRIDE:-$(cat lib.lock)}
mkdir -p .deps
if ! git -C ../lib show "$pin:lib.py" > .deps/lib.py 2>/dev/null; then
  echo "check: cannot resolve lib at pinned commit $(echo "$pin" | cut -c1-7) in ../lib"
  exit 2
fi
echo "check: lib resolved from lib.lock at $(git -C ../lib rev-parse --short "$pin") (../lib HEAD is $(git -C ../lib rev-parse --short HEAD))"
PYTHONPATH=.deps python3 -B test_app.py
EOF
  chmod +x "$1/check.sh"
  printf '.deps/\n' > "$1/.gitignore"
}

write_app_B0() { # dir mech
  cat > "$1/app.py" <<'EOF'
from lib import greet

def banner():
    return greet("world")
EOF
  cat > "$1/test_app.py" <<'EOF'
from app import banner
assert banner() == "Hello, world"
print("app tests passed")
EOF
  "write_app_check_$2" "$1"
}

# Build mainline A0 (lib) and B0 (app) plus a Worktree per Repo on feature/yh-1.
setup() { # root mech
  R=$1
  mkdir -p "$R/clones/lib" "$R/clones/app" "$R/wt"
  git -C "$R/clones/lib" init -q -b main
  write_lib_A0 "$R/clones/lib"
  git -C "$R/clones/lib" add -A
  commit "$R/clones/lib" "A0: lib mainline, greet(name)"
  A0=$(git -C "$R/clones/lib" rev-parse HEAD)
  git -C "$R/clones/app" init -q -b main
  write_app_B0 "$R/clones/app" "$2"
  [ "$2" = pin ] && echo "$A0" > "$R/clones/app/lib.lock"
  git -C "$R/clones/app" add -A
  commit "$R/clones/app" "B0: app mainline, banner() uses greet"
  git -C "$R/clones/lib" worktree add -q -b feature/yh-1 "$R/wt/lib" main
  git -C "$R/clones/app" worktree add -q -b feature/yh-1 "$R/wt/app" main
  echo "worktrees: wt/lib and wt/app on feature/yh-1 (siblings)"
}

# --- Case 1 changes: A1 removes greet; B1 adds a second use of greet ----------

lib_A1_remove_greet() { # dir
  cat > "$1/lib.py" <<'EOF'
def greeting(name):
    return "Hello, " + name + "!"
EOF
  cat > "$1/test_lib.py" <<'EOF'
from lib import greeting
assert greeting("x") == "Hello, x!"
print("lib tests passed")
EOF
  git -C "$1" add -A
  commit "$1" "A1: replace greet(name) with greeting(name)"
}

app_B1_add_greet_use() { # dir
  cat >> "$1/app.py" <<'EOF'

def welcome(user):
    return greet(user) + ", welcome back"
EOF
  cat >> "$1/test_app.py" <<'EOF'
from app import welcome
assert welcome("Ann") == "Hello, Ann, welcome back"
print("welcome tests passed")
EOF
  git -C "$1" add -A
  commit "$1" "B1: add welcome(user) using greet"
}

# --- Case 2 changes: A1 renames greet to hello; B1 switches to hello -----------

lib_A1_rename() { # dir
  cat > "$1/lib.py" <<'EOF'
def hello(name):
    return "Hello, " + name
EOF
  sed -i '' 's/greet/hello/g' "$1/test_lib.py"
  git -C "$1" add -A
  commit "$1" "A1: rename greet(name) to hello(name)"
}

lib_A1_additive() { # dir   backward-compatible variant: hello added, greet kept
  cat > "$1/lib.py" <<'EOF'
def hello(name):
    return "Hello, " + name

def greet(name):
    return hello(name)
EOF
  cat >> "$1/test_lib.py" <<'EOF'
from lib import hello
assert hello("x") == "Hello, x"
EOF
  git -C "$1" add -A
  commit "$1" "A1: add hello(name), keep greet(name) as an alias"
}

app_B1_switch() { # dir [pin-sha]
  sed -i '' 's/greet/hello/g' "$1/app.py"
  if [ $# -ge 2 ]; then
    echo "$2" > "$1/lib.lock"
    git -C "$1" add -A
    commit "$1" "B1: switch banner() to hello; bump lib.lock to $(echo "$2" | cut -c1-7)"
  else
    git -C "$1" add -A
    commit "$1" "B1: switch banner() to hello"
  fi
}

# =========================================================================
echo "### git $(git --version | cut -d' ' -f3), python $(python3 --version | cut -d' ' -f2)"

echo
echo "=== Case 1 / sibling path (M1): separately green, combined red ==="
R=$WORK/case1-path; setup "$R" path
app_B1_add_greet_use "$R/wt/app"
echo "-- B's Check, run while wt/lib is still at A0:"
run_check "$R/wt/app"
lib_A1_remove_greet "$R/wt/lib"
echo "-- A's Check:"
run_check "$R/wt/lib"
echo "-- Combined A1+B1: B's Check again, wt/app unchanged, wt/lib now at A1:"
run_check "$R/wt/app"

echo
echo "=== Case 1 / pinned commit (M2): separately green, combined red? ==="
R=$WORK/case1-pin; setup "$R" pin
app_B1_add_greet_use "$R/wt/app"
lib_A1_remove_greet "$R/wt/lib"
A1=$(git -C "$R/wt/lib" rev-parse HEAD)
echo "-- A's Check:"
run_check "$R/wt/lib"
echo "-- B's Check with both Feature Branches at their tips (wt/lib at A1):"
run_check "$R/wt/app"
echo "-- B1's code against A1, via an override that neither commit declares:"
echo "\$ cd \$WORK/case1-pin/wt/app && LIB_PIN_OVERRIDE=$(echo "$A1" | cut -c1-7) ./check.sh"
out=$(cd "$R/wt/app" && LIB_PIN_OVERRIDE=$A1 ./check.sh 2>&1); st=$?
printf '%s\n' "$out" | sed 's/^/  | /'
echo "  exit status: $st"

for ORDER in lib-first app-first; do
  echo
  echo "=== Case 2 / sibling path (M1), merge order $ORDER: combined green, intermediate red ==="
  R=$WORK/case2-path-$ORDER; setup "$R" path
  lib_A1_rename "$R/wt/lib"
  app_B1_switch "$R/wt/app"
  echo "-- A's and B's Checks with both Feature Branches at their tips (A1+B1):"
  run_check "$R/wt/lib"
  run_check "$R/wt/app"
  if [ "$ORDER" = lib-first ]; then
    merge "$R/clones/lib" feature/yh-1 "merge lib feature/yh-1 into main"
    echo "-- Intermediate A1+B0: B's Check on app mainline, sibling clones/lib on its mainline:"
    run_check "$R/clones/app"
    merge "$R/clones/app" feature/yh-1 "merge app feature/yh-1 into main"
  else
    merge "$R/clones/app" feature/yh-1 "merge app feature/yh-1 into main"
    echo "-- Intermediate A0+B1: B's Check on app mainline, sibling clones/lib on its mainline:"
    run_check "$R/clones/app"
    merge "$R/clones/lib" feature/yh-1 "merge lib feature/yh-1 into main"
  fi
  echo "-- Both merged:"
  run_check "$R/clones/app"
done

for ORDER in lib-first app-first; do
  echo
  echo "=== Case 2b / sibling path (M1), backward-compatible A1, merge order $ORDER ==="
  R=$WORK/case2b-path-$ORDER; setup "$R" path
  lib_A1_additive "$R/wt/lib"
  app_B1_switch "$R/wt/app"
  echo "-- A1+B1 at the Feature Branch tips:"
  run_check "$R/wt/lib"
  run_check "$R/wt/app"
  if [ "$ORDER" = lib-first ]; then
    merge "$R/clones/lib" feature/yh-1 "merge lib feature/yh-1 into main"
    echo "-- Intermediate A1+B0:"
  else
    merge "$R/clones/app" feature/yh-1 "merge app feature/yh-1 into main"
    echo "-- Intermediate A0+B1:"
  fi
  run_check "$R/clones/app"
done

for ORDER in lib-first app-first; do
  echo
  echo "=== Case 2 / pinned commit (M2), merge order $ORDER ==="
  R=$WORK/case2-pin-$ORDER; setup "$R" pin
  lib_A1_rename "$R/wt/lib"
  A1=$(git -C "$R/wt/lib" rev-parse HEAD)
  app_B1_switch "$R/wt/app" "$A1"
  echo "-- A1+B1 at the Feature Branch tips:"
  run_check "$R/wt/lib"
  run_check "$R/wt/app"
  if [ "$ORDER" = lib-first ]; then
    merge "$R/clones/lib" feature/yh-1 "merge lib feature/yh-1 into main"
    echo "-- Intermediate A1+B0 (clones/app main still pins A0):"
    run_check "$R/clones/app"
  else
    merge "$R/clones/app" feature/yh-1 "merge app feature/yh-1 into main"
    echo "-- Intermediate A0+B1 in the main clones (clones/lib still holds feature/yh-1 objects):"
    run_check "$R/clones/app"
    echo "-- Intermediate A0+B1 in fresh clones of each mainline only:"
    mkdir -p "$R/fresh"
    echo "\$ git clone --no-local --single-branch -b main \$WORK/${R#"$WORK"/}/clones/lib \$WORK/${R#"$WORK"/}/fresh/lib"
    echo "\$ git clone --no-local --single-branch -b main \$WORK/${R#"$WORK"/}/clones/app \$WORK/${R#"$WORK"/}/fresh/app"
    git clone -q --no-local --single-branch -b main "$R/clones/lib" "$R/fresh/lib"
    git clone -q --no-local --single-branch -b main "$R/clones/app" "$R/fresh/app"
    echo "\$ git -C \$WORK/${R#"$WORK"/}/fresh/lib cat-file -t $(echo "$A1" | cut -c1-7)"
    git -C "$R/fresh/lib" cat-file -t "$A1" 2>&1 | sed 's/^/  | /'
    run_check "$R/fresh/app"
    echo "-- The same single-branch clone without --no-local (git's local-path optimisation):"
    echo "\$ git clone --single-branch -b main \$WORK/${R#"$WORK"/}/clones/lib \$WORK/${R#"$WORK"/}/local-lib"
    git clone -q --single-branch -b main "$R/clones/lib" "$R/local-lib"
    echo "\$ git -C \$WORK/${R#"$WORK"/}/local-lib cat-file -t $(echo "$A1" | cut -c1-7)"
    git -C "$R/local-lib" cat-file -t "$A1" 2>&1 | sed 's/^/  | /'
    echo "\$ git -C \$WORK/${R#"$WORK"/}/local-lib branch -a"
    git -C "$R/local-lib" branch -a 2>&1 | sed 's/^/  | /'
  fi
done
