# #708 step 2: cross-repository Check reproduction

## Purpose

[yellowhammer#708](https://github.com/summerhammer/yellowhammer/issues/708) recommends, as investigation
step 2, using two disposable repositories to try to reproduce (a) Checks that are each green while the
combined state is red, and (b) a combined state that is green while an intermediate merge state is red.
This document records that attempt. The result feeds spec question
[OQ198](https://github.com/summerhammer/yellowhammer-spec/blob/main/docs/requirements/vision/risks.md#oq198)
("decide after yellowhammer#708's investigation tries to reproduce a cross-repository failure (its step
2)"), and touches the residual of R15 and the known limitation in
`verification/verify-a-feature-clause-by-clause#judged-checkout-limitation` ("the commits in the
checkout are not always what a Check consumed (a lock file can pin an older commit)"). It reports what
was and was not reproduced. It does not propose a merge order or a spec change.

The scenarios touch the moved Feature Branch, the reuse of a recorded Verification and the tested
revision matrix only as context. Those are separate tracks of #708.

- Date: 2026-10-30
- git 2.53.0, Python 3.11.4, `/bin/sh`, BSD (macOS) `sed`, macOS 27.0.1 (arm64)
- Local repositories only. No network, no remotes, no installs. Yellowhammer itself was not run: the
  Checks here are run by hand, in the way the engine runs a Repo's Check (a command in that Repo's
  directory).

## How to run

```sh
WORK=/path/to/an/empty/dir sh doc/investigations/708-cross-repo-reproduce.sh
```

`708-cross-repo-reproduce.sh` is next to this file. It refuses a non-empty `$WORK`. Names, emails and dates are fixed,
and the user's git config is ignored (`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`), so commit
shas are the same on every run. Two runs from empty directories gave byte-identical output (after the
`$WORK` path is substituted). Every short sha below comes from that output.

## Setup

Two Repos:

- **`lib`**, the producer. `lib.py` defines `greet(name)`. Its Check is
  ```sh
  #!/bin/sh
  python3 -B test_lib.py
  ```
- **`app`**, the consumer. `app.py` defines `banner()`, which calls `lib.greet`. Its test asserts
  `banner() == "Hello, world"`.

Each scenario builds a fresh pair under `$WORK/<scenario>/`:

```
$WORK/<scenario>/clones/lib    main clone, branch main   (mainline)
$WORK/<scenario>/clones/app    main clone, branch main   (mainline)
$WORK/<scenario>/wt/lib        git worktree, Feature Branch feature/yh-1
$WORK/<scenario>/wt/app        git worktree, Feature Branch feature/yh-1
```

The Worktrees are siblings, so `../lib` from `wt/app` is `lib`'s Worktree, and `../lib` from
`clones/app` is `lib`'s main clone. This models the Worktrees' directory layout that the OQ191 ruling
keeps for the verifier's checkouts. One Feature has one Feature Branch per Repo. The worktrees are made
with

```sh
git -C $WORK/<scenario>/clones/lib worktree add -b feature/yh-1 $WORK/<scenario>/wt/lib main
git -C $WORK/<scenario>/clones/app worktree add -b feature/yh-1 $WORK/<scenario>/wt/app main
```

A merge to mainline is `git -C clones/<repo> merge --no-ff feature/yh-1` in the main clone.

The consumer resolves the producer in one of two ways. Only `app`'s `check.sh` differs.

**M1, sibling path.** The Check imports `lib` from the sibling directory as it stands:

```sh
#!/bin/sh
echo "check: lib resolved from ../lib at $(git -C ../lib rev-parse --short HEAD)"
PYTHONPATH=../lib python3 -B test_app.py
```

**M2, pinned commit.** `app` commits `lib.lock`, which holds a full `lib` commit sha. The Check extracts
`lib.py` at that commit from the sibling repository's object store into an ignored `.deps/`:

```sh
#!/bin/sh
pin=${LIB_PIN_OVERRIDE:-$(cat lib.lock)}
mkdir -p .deps
if ! git -C ../lib show "$pin:lib.py" > .deps/lib.py 2>/dev/null; then
  echo "check: cannot resolve lib at pinned commit $(echo "$pin" | cut -c1-7) in ../lib"
  exit 2
fi
echo "check: lib resolved from lib.lock at $(git -C ../lib rev-parse --short "$pin") (../lib HEAD is $(git -C ../lib rev-parse --short HEAD))"
PYTHONPATH=.deps python3 -B test_app.py
```

`LIB_PIN_OVERRIDE` exists only to show B1's code against A1 in Case 1 / M2. No commit declares it.

The `check: lib resolved …` line is printed by these test Checks. It is the only evidence of which
producer revision a run used. The Check record that the verifier is handed (command, the commit the
Check ran on, exit status, per `#recorded-check-results`) does not carry it.

Neither mechanism is one of the two kinds a Repo Dependency declares (`mainline` or `tag`). M1 is
nearest to `mainline` read through the sibling layout. M2 is a lockfile pin.

In the spec, a Feature that touches both ends of a declared Repo Dependency is an Authoring Halt (glossary,
*Repo Dependency*). So the Feature modelled here, one Feature with Feature Branches in both `lib` and
`app`, exists only where no edge between them is declared. That is part of R15's residual ("an
undeclared edge").

Long Python tracebacks are trimmed to their last line below. Paths are shown relative to `$WORK`.

## Case 1: separately green, combined red

Changes:

- **A1** (`lib`): replace `greet(name)` with `greeting(name)`, which returns `"Hello, " + name + "!"`. The
  `lib` test is updated to match.
- **B1** (`app`): add `welcome(user)`, which calls `greet`, and a test for it.

### M1, sibling path: reproduced

| sha | Repo | meaning |
|---|---|---|
| `a6afcab` | lib main | A0: `greet(name)` |
| `3e40c9b` | app main | B0: `banner()` uses `greet` |
| `58d749b` | app feature/yh-1 | B1: add `welcome(user)` using `greet` |
| `7aa4fcf` | lib feature/yh-1 | A1: replace `greet` with `greeting` |

The order of events: B1 is committed and B's Check runs while `wt/lib` is still at A0. Then A1 is
committed and A's Check runs. Then B's Check runs again, with nothing in `wt/app` changed.

```
-- B's Check, run while wt/lib is still at A0:
$ cd $WORK/case1-path/wt/app && ./check.sh    # HEAD 58d749b (feature/yh-1)
  | check: lib resolved from ../lib at a6afcab
  | app tests passed
  | welcome tests passed
  exit status: 0
commit 7aa4fcf in case1-path/wt/lib: A1: replace greet(name) with greeting(name)
-- A's Check:
$ cd $WORK/case1-path/wt/lib && ./check.sh    # HEAD 7aa4fcf (feature/yh-1)
  | lib tests passed
  exit status: 0
-- Combined A1+B1: B's Check again, wt/app unchanged, wt/lib now at A1:
$ cd $WORK/case1-path/wt/app && ./check.sh    # HEAD 58d749b (feature/yh-1)
  | check: lib resolved from ../lib at 7aa4fcf
  | …
  | ImportError: cannot import name 'greet' from 'lib' (…/case1-path/wt/lib/lib.py)
  exit status: 1
```

**Reproduced.** A's Check is green at A1 (`7aa4fcf`). B's Check is green at B1 (`58d749b`), with `lib`
resolved at A0 (`a6afcab`). B's Check at the same B1 is red when the sibling is at A1. The two runs of B's
Check have the same directory, the same command and the same app commit. They differ only in the
sibling's HEAD at run time. A record of (command, `58d749b`, exit 0) cannot tell the green run from
the red one.

B0 also calls `greet`, so A1+B0 is red too. A1 breaks the consumer whatever B does. B1 only adds a second
call.

### M2, pinned commit: not reproduced with the committed state; reproduced only with an override

| sha | Repo | meaning |
|---|---|---|
| `789354e` | lib main | A0 |
| `61a8518` | app main | B0, `lib.lock` = A0 |
| `8abaeef` | app feature/yh-1 | B1: add `welcome(user)` using `greet`; `lib.lock` unchanged (A0) |
| `88b0589` | lib feature/yh-1 | A1: replace `greet` with `greeting` |

```
-- A's Check:
$ cd $WORK/case1-pin/wt/lib && ./check.sh    # HEAD 88b0589 (feature/yh-1)
  | lib tests passed
  exit status: 0
-- B's Check with both Feature Branches at their tips (wt/lib at A1):
$ cd $WORK/case1-pin/wt/app && ./check.sh    # HEAD 8abaeef (feature/yh-1)
  | check: lib resolved from lib.lock at 789354e (../lib HEAD is 88b0589)
  | app tests passed
  | welcome tests passed
  exit status: 0
-- B1's code against A1, via an override that neither commit declares:
$ cd $WORK/case1-pin/wt/app && LIB_PIN_OVERRIDE=88b0589 ./check.sh
  | check: lib resolved from lib.lock at 88b0589 (../lib HEAD is 88b0589)
  | …
  | ImportError: cannot import name 'greet' from 'lib' (…/case1-pin/wt/app/.deps/lib.py)
  exit status: 1
```

The log line says "from lib.lock", but that run took the commit from `LIB_PIN_OVERRIDE`.

**Not reproduced as committed.** With both Feature Branches at their tips, B's Check is green, because
B1 consumes A0 (`789354e`) through `lib.lock`, not the A1 (`88b0589`) that the sibling Worktree holds.
B1's code is red against A1 only through `LIB_PIN_OVERRIDE`, and no commit in either Repo declares that
combination. Its first real occurrence would be a later commit that bumps `lib.lock`.

## Case 2: combined green, intermediate red

Changes:

- **A1** (`lib`): rename `greet(name)` to `hello(name)` and remove `greet`.
- **B1** (`app`): switch `banner()` to `hello`. Under M2, B1 also sets `lib.lock` to A1's sha.

Each merge order is a separate, freshly built pair (`case2-*-lib-first`, `case2-*-app-first`). An
"intermediate" state is a mainline after one Repo's Feature Branch is merged and before the other's. B's
Check runs in `clones/app` (app's mainline), with `../lib` being lib's main clone on its mainline.

### M1, sibling path: reproduced in both orders

lib merged first:

| sha | Repo | meaning |
|---|---|---|
| `c8958a0` | lib main | A0 |
| `9a6d962` | app main | B0 |
| `d4faed3` | lib feature/yh-1 | A1: rename `greet` to `hello` |
| `f70957f` | app feature/yh-1 | B1: switch `banner()` to `hello` |
| `d14470d` | lib main | merge of A1 into lib main |
| `e18bfce` | app main | merge of B1 into app main |

```
$ cd $WORK/case2-path-lib-first/wt/lib && ./check.sh    # HEAD d4faed3 (feature/yh-1)
  | lib tests passed
  exit status: 0
$ cd $WORK/case2-path-lib-first/wt/app && ./check.sh    # HEAD f70957f (feature/yh-1)
  | check: lib resolved from ../lib at d4faed3
  | app tests passed
  exit status: 0
merge  d14470d in case2-path-lib-first/clones/lib: merge lib feature/yh-1 into main
-- Intermediate A1+B0: B's Check on app mainline, sibling clones/lib on its mainline:
$ cd $WORK/case2-path-lib-first/clones/app && ./check.sh    # HEAD 9a6d962 (main)
  | check: lib resolved from ../lib at d14470d
  | …
  | ImportError: cannot import name 'greet' from 'lib' (…/case2-path-lib-first/clones/lib/lib.py)
  exit status: 1
merge  e18bfce in case2-path-lib-first/clones/app: merge app feature/yh-1 into main
-- Both merged:
$ cd $WORK/case2-path-lib-first/clones/app && ./check.sh    # HEAD e18bfce (main)
  | check: lib resolved from ../lib at d14470d
  | app tests passed
  exit status: 0
```

app merged first (A0 `6bdd950`, B0 `2ca1b50`, A1 `b75fadf`, B1 `b901872`, app merge `0e124b0`, lib merge
`a280fa8`):

```
$ cd $WORK/case2-path-app-first/wt/app && ./check.sh    # HEAD b901872 (feature/yh-1)
  | check: lib resolved from ../lib at b75fadf
  | app tests passed
  exit status: 0
merge  0e124b0 in case2-path-app-first/clones/app: merge app feature/yh-1 into main
-- Intermediate A0+B1: B's Check on app mainline, sibling clones/lib on its mainline:
$ cd $WORK/case2-path-app-first/clones/app && ./check.sh    # HEAD 0e124b0 (main)
  | check: lib resolved from ../lib at 6bdd950
  | …
  | ImportError: cannot import name 'hello' from 'lib' (…/case2-path-app-first/clones/lib/lib.py)
  exit status: 1
merge  a280fa8 in case2-path-app-first/clones/lib: merge lib feature/yh-1 into main
-- Both merged:
$ cd $WORK/case2-path-app-first/clones/app && ./check.sh    # HEAD 0e124b0 (main)
  | check: lib resolved from ../lib at a280fa8
  | app tests passed
  exit status: 0
```

A's Check is green at A1 in both pairs (`lib tests passed`, exit 0).

**Reproduced.** A1+B1 is green at the Feature Branch tips, and green again once both are merged.
A1+B0 (lib merged first) is red, and so is A0+B1 (app merged first). This A1 is a breaking change across
the two Repos. The spec treats atomic breaking changes across repositories as unsupported (#708,
"Analysis and product constraints").

### Case 2b, M1 with a backward-compatible A1: intermediate red in one order only

A1 adds `hello(name)` and keeps `greet(name)` as an alias. B1 is unchanged.

| order | shas (A0, B0, A1, B1, merge) | A1+B1 at tips | intermediate | result |
|---|---|---|---|---|
| lib first | `946b421`, `1b2f845`, `06703bb`, `1d1f743`, lib merge `49da259` | exit 0 (`lib` at `06703bb`) | A1+B0: `check: lib resolved from ../lib at 49da259` … `app tests passed`, exit 0 | green |
| app first | `fb450b3`, `f88c67d`, `ca807a3`, `8e946c5`, app merge `9305e56` | exit 0 (`lib` at `ca807a3`) | A0+B1: `check: lib resolved from ../lib at fb450b3` … `ImportError: cannot import name 'hello' from 'lib'`, exit 1 | red |

**Reproduced for one order.** With a backward-compatible A1, the intermediate state is green in one
merge order and red in the other.

### M2, pinned commit: no Check-level red; red only as a resolution failure in a mainline-only clone

lib merged first (A0 `24e7691`, B0 `fd2f3d8` pinning A0, A1 `27f0176`, B1 `1cdc18a` pinning `27f0176`, lib
merge `e719a9b`):

```
$ cd $WORK/case2-pin-lib-first/wt/app && ./check.sh    # HEAD 1cdc18a (feature/yh-1)
  | check: lib resolved from lib.lock at 27f0176 (../lib HEAD is 27f0176)
  | app tests passed
  exit status: 0
merge  e719a9b in case2-pin-lib-first/clones/lib: merge lib feature/yh-1 into main
-- Intermediate A1+B0 (clones/app main still pins A0):
$ cd $WORK/case2-pin-lib-first/clones/app && ./check.sh    # HEAD fd2f3d8 (main)
  | check: lib resolved from lib.lock at 24e7691 (../lib HEAD is e719a9b)
  | app tests passed
  exit status: 0
```

app merged first (A0 `59a6c8b`, B0 `378ffd9`, A1 `8bdb75c`, B1 `8b64b5f` pinning `8bdb75c`, app merge
`3b389aa`):

```
$ cd $WORK/case2-pin-app-first/wt/app && ./check.sh    # HEAD 8b64b5f (feature/yh-1)
  | check: lib resolved from lib.lock at 8bdb75c (../lib HEAD is 8bdb75c)
  | app tests passed
  exit status: 0
merge  3b389aa in case2-pin-app-first/clones/app: merge app feature/yh-1 into main
-- Intermediate A0+B1 in the main clones (clones/lib still holds feature/yh-1 objects):
$ cd $WORK/case2-pin-app-first/clones/app && ./check.sh    # HEAD 3b389aa (main)
  | check: lib resolved from lib.lock at 8bdb75c (../lib HEAD is 59a6c8b)
  | app tests passed
  exit status: 0
-- Intermediate A0+B1 in fresh clones of each mainline only:
$ git clone --no-local --single-branch -b main $WORK/case2-pin-app-first/clones/lib $WORK/case2-pin-app-first/fresh/lib
$ git clone --no-local --single-branch -b main $WORK/case2-pin-app-first/clones/app $WORK/case2-pin-app-first/fresh/app
$ git -C $WORK/case2-pin-app-first/fresh/lib cat-file -t 8bdb75c
  | fatal: git cat-file: could not get object info
$ cd $WORK/case2-pin-app-first/fresh/app && ./check.sh    # HEAD 3b389aa (main)
  | check: cannot resolve lib at pinned commit 8bdb75c in ../lib
  exit status: 2
-- The same single-branch clone without --no-local (git's local-path optimisation):
$ git clone --single-branch -b main $WORK/case2-pin-app-first/clones/lib $WORK/case2-pin-app-first/local-lib
$ git -C $WORK/case2-pin-app-first/local-lib cat-file -t 8bdb75c
  | commit
$ git -C $WORK/case2-pin-app-first/local-lib branch -a
  | * main
  |   remotes/origin/main
```

**Not reproduced as a failing test.** A1+B1 is green. A1+B0 is green, because B0 still pins A0. A0+B1 is
green in the main clones, because `clones/lib` shares its object store with the `wt/lib` Worktree, so
B1's pin `8bdb75c` resolves even though lib's mainline does not contain it. A0+B1 is red only where
`../lib` is a clone of lib's mainline alone (`--no-local --single-branch -b main`). There the Check fails
at resolution (exit 2), before any test runs. The same single-branch clone without `--no-local` still
holds `8bdb75c`: git's local-path clone copies the object store, so an unmerged commit resolves although
no ref names it.

## Extra observation: consumed revision ≠ sibling checkout's HEAD

Under M2, all of these runs consumed a `lib` commit other than the HEAD of the adjacent `../lib`
checkout:

| run | `../lib` HEAD | `lib` consumed |
|---|---|---|
| Case 1 / M2, B's Check at B1 `8abaeef` | `88b0589` (A1) | `789354e` (A0) |
| Case 2 / M2 lib first, B's Check on app main `fd2f3d8` | `e719a9b` (lib main after merge) | `24e7691` (A0) |
| Case 2 / M2 app first, B's Check on app main `3b389aa` | `59a6c8b` (A0) | `8bdb75c` (A1, not on lib mainline) |

Under M2 the consumer's commit does determine the consumed revision: it is in the committed `lib.lock`
(when no override is set). What does not match it is the adjacent `../lib` checkout's HEAD. The Check
record (command, the commit the Check ran on, exit status) does not show the consumed revision unless
`lib.lock` is read from that commit's tree.

Under M1 the consumer's commit carries nothing about the producer revision. The consumed revision always
equalled the sibling's HEAD, but that HEAD is read when the Check runs, not when the app commit was made,
so the same app commit consumed `a6afcab` in one run and `7aa4fcf` in the next (Case 1 / M1). Only the
Check's own `check: lib resolved …` line recorded which.

## What this shows and does not show

Shows, for these two toy Repos and these two resolution mechanisms:

- Case 1 (separately green, combined red) was reproduced under M1 (sibling path). It depended on the
  sibling's HEAD at the time B's Check ran. The (command, app commit, exit status) triple was the same
  for the green run and the red run.
- Case 1 was not reproduced under M2 (pinned commit) for any committed state. The combined Feature
  Branches consumed A0 and were green. B1's code is red against A1 only through an override that no commit
  declares.
- Case 2 (combined green, intermediate red) was reproduced under M1 in both merge orders for a breaking
  A1, and in one order (app first) for a backward-compatible A1.
- Under M2, Case 2 gave no failing test in any intermediate state run. The only red was a resolution
  failure (exit 2) for A0+B1 when `../lib` held lib's mainline objects only. Whether that state is red
  depended on how `../lib` was cloned (`--no-local` or not), not on any commit.
- Under M1, the consumer's commit and the Check's exit status did not identify the producer revision the
  Check consumed. Only output that the Check itself printed did.
- Under M2, the consumer's commit did identify it, through the committed `lib.lock`. The adjacent
  `../lib` checkout's HEAD did not match it in the three runs listed above.

Does not show:

- Anything about Yellowhammer's engine. No `yh` Act, Journal or Verification was run. The Checks were run
  by hand in the same layout. Whether, and in what order, the engine runs Checks while a sibling
  Worktree moves was not examined here.
- Resolution through a Repo Dependency's declared `tag` kind or an Observed Release, a package manager
  lockfile (SwiftPM `Package.resolved`, npm), a git submodule, a vendored copy, a generated client or a
  running service. Only a sibling path and a hand-rolled commit pin were tried.
- Real-world frequency. These are constructed toy changes.
- The other step 2 sub-cases: a moved Feature Branch, a changed dependency pin between land Acts, and
  reuse of a recorded Verification. These are covered by other tracks.

Remaining unknowns:

- Whether a real Yellowhammer Night can produce the Case 1 / M1 timing, with B's Check run while `lib`'s
  Worktree is at A0 and `lib`'s Work Card committed afterwards, within one Feature.
- Which resolution mechanisms the Repos of real Projects use, and so which of M1 and M2 (or neither)
  applies to them. That is #708 step 3.
- Whether the verifier's fresh checkout (OQ191 item 8) holds the producer objects a pin names. Here it
  depended on the clone method.
