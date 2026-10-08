# Throwaway repositories and fixtures (P15.2)

`rehearsal_fixtures.py` builds the throwaway git fixture tree a rehearsal Night runs against,
and lets you apply pre-baked scenarios to it between Nights — standing in for what a human or
another contributor does to a shared remote. See `scripts/scratch-linear/README.md` for the
scratch Linear board side of the same rehearsal environment; this tool is unrelated to it and
never touches Linear.

A rehearsal Night never dispatches an agent CLI (result files come from fixtures bundled in the
engine), never pushes, never opens a pull request. The engine refreshes each working Repo with
`git fetch origin <default>` — the default branch resolved from `refs/remotes/origin/HEAD`, else
`origin/main` — so every working Repo this tool builds has a local bare remote and a clone whose
`origin` points at it, with `refs/remotes/origin/HEAD` set. The Spec Source is read locally at
HEAD and never fetched, so it is a plain local repository with no remote at all.

## The shape of a built tree

```
DIR/<Project ID>/
  .yellowhammer-rehearsal-fixtures   # marker: this tree was built by this tool
  manifest.json                      # paths, repo roles, protected paths, spec stories/goals, scenario refs
  project-repos.toml                 # spec_source + [[repos]] tables, ready to paste into the Project file
  remotes/
    fixture-backend.git              # bare
    fixture-web.git                  # bare
    fixture-mobile.git               # bare
  repos/
    fixture-backend/                 # clone, origin -> remotes/fixture-backend.git, branch main
    fixture-web/
    fixture-mobile/
  spec/                              # Spec Source: local repo, no remote
    docs/requirements/vision/goals.md
    docs/requirements/epics/fixture-epic/overview.md
    docs/requirements/epics/fixture-epic/stories/fixture-story.md
    docs/requirements/epics/fixture-epic/stories/fixture-story-2.md
```

Every commit is made with a fixed author/committer identity and fixed, deterministic dates (not
wall-clock), and `GIT_CONFIG_GLOBAL=/dev/null` / `GIT_CONFIG_NOSYSTEM=1` so the developer's own
git config never leaks in. Two builds of the same Project produce byte-identical SHAs.

**Which bundled engine result fixture this pairs with:** the engine's default breakdown result
fixture (`breakdown-drafted-with-contract.json`, paired with `selection-selected-with-contract.json`)
names repositories `fixture-backend` and `fixture-web` and cites the story
`fixture-epic/fixture-story`; its fixture-web Card transcribes the contract path
`contracts/fixture-api.json` from fixture-backend's mainline. This tool's `fixture-backend` and
`fixture-web` repos, and its `fixture-epic/fixture-story` story (with acceptance criteria), are
built to match that fixture exactly. `fixture-mobile` and the second story (`fixture-story-2`)
exist so a Project can exercise more than one Repo/story without colliding with the bundled
fixture's names — which is also what the three-repository fixture pair
(`selection-selected-three-repos.json` / `breakdown-drafted-three-repos.json`, P15.3) exercises:
five Cards across all three repos, citing both stories, with the same fixture-web/fixture-backend
contract. `selection-selected-adopting.json` (P15.3, pairs with `breakdown-drafted-with-contract.json`)
selects the same two repositories but leaves `adopted_card_issue_ids` for
``RehearsalDispatch`` to synthesize from whichever Blocked Cards this tree's Project has left behind.

`fixture-backend` additionally carries `migrations/0001_init.sql`, and `migrations/` is its one
protected path (`protected_paths = ["migrations/"]` in `project-repos.toml`) — see *Protected
Paths refusal* below.

## Building a tree

```sh
python3 scripts/rehearsal-fixtures/rehearsal_fixtures.py build \
  --root /private/tmp/claude-501/p152-fixtures \
  --project rehearsal-a --project rehearsal-b
```

Refuses (exit 2, nothing changed) if `DIR/<ID>` already exists and either has no marker file (it
is not this tool's tree — never delete something it didn't build) or has the marker but `--force`
was not given. Pass `--force` to delete and rebuild an already-marked tree. Also refuses if `DIR`
itself is inside a git work tree, so this never runs against a checkout of Yellowhammer or any
other real repository by mistake.

`build` prints the matching `yh setup --init` invocation for each Project, e.g.:

```sh
yh setup --init --project rehearsal-a \
  --spec-source /private/tmp/claude-501/p152-fixtures/rehearsal-a/spec --skip-github-check \
  --repo 'fixture-backend,backend,/private/tmp/claude-501/p152-fixtures/rehearsal-a/repos/fixture-backend,true' \
  --repo 'fixture-web,web,/private/tmp/claude-501/p152-fixtures/rehearsal-a/repos/fixture-web,true' \
  --repo 'fixture-mobile,mobile,/private/tmp/claude-501/p152-fixtures/rehearsal-a/repos/fixture-mobile,true'
```

`--skip-github-check` is there because the fixture repositories' `origin` is a local bare repository, with no
GitHub token behind it: without the flag `yh setup` refuses the Project. A rehearsal Night never pushes, so
nothing is lost; `yh doctor` still reports the missing GitHub check.

`project-repos.toml` in the built tree holds the same information as TOML, ready to paste into
the Project file (add the scratch Linear team/project fields yourself — see
`scripts/scratch-linear/README.md`).

## Applying a scenario

```sh
python3 scripts/rehearsal-fixtures/rehearsal_fixtures.py apply SCENARIO \
  --root DIR --project ID [--repo NAME ...] [--branch B | --feature NAME]
```

`apply` only ever writes to the throwaway bare remotes and, for `conflicting-branch`, a throwaway
clone. It never touches Worktrees or Linear. `--feature NAME` computes the Feature Branch name
the same way the engine does (`feature_branch(project, feature)`, replicating
`Packages/YellowhammerKit/Sources/Domain/FeatureBranch.swift`'s sanitising exactly) instead of
naming a raw `--branch`.

Every `apply` either changes nothing and exits non-zero, or makes all of its changes — never a
partial state. Every precondition (branch absence, whether a change can land at all) is checked,
per repo and across the whole `--repo` list, before anything is written.

### Composing scenarios

The three fast-forward scenarios below (`mainline-moved`, `transcription-path-touched`,
`mainline-conflict`) are meant to be applied in sequence, standing in for several independent
things happening to a shared remote between rehearsal Nights — e.g. the P15.3 suite applies
`mainline-moved`, then `transcription-path-touched`, then creates a `conflicting-branch`, all
against the same tree.

Each scenario's pre-baked ref is a single commit built on top of the tree's *original* mainline —
so once an earlier scenario has moved `main` away from that original tip, a later scenario's ref
is no longer a descendant of the *current* `main`. Rather than refuse in that case, `apply`:

1. Checks whether the ref's change is already present on `main` (comparing the one file each
   scenario touches — `NOTES.md`, `contracts/fixture-api.json`, `conflict.txt` respectively) — if
   so, it is a no-op, whether or not the two commits are otherwise related.
2. Otherwise, if the current `main` actually is an ancestor of the ref, it fast-forwards, exactly
   as before.
3. Otherwise it **replays**: cherry-picks the pre-baked commit onto the *current* `main` in a
   disposable scratch clone under the tree, keeping the same fixed author/committer identity and a
   fixed date (never wall-clock), and pushes the result — a new commit on `main` carrying both the
   earlier changes and this scenario's, exactly as another contributor pushing on top of what's
   already there would look. Every earlier scenario's already-landed change survives a later
   scenario's replay, since the replay's base *is* the current `main`.

If the replay itself would conflict (two scenarios touching the same file incompatibly), `apply`
refuses with exit 1 and changes nothing — this is checked in a disposable dry run before any
write, so a refusal never leaves a half-applied replay behind.

### `mainline-moved` — predecessor-ancestry gate

Fast-forwards or replays (see *Composing scenarios*) the remote's `main` to include the pre-baked
`mainline-moved` commit (touching an unrelated file `NOTES.md`), in every working repo by default,
or just the `--repo` you name. Exercises the engine's predecessor-ancestry gate: a Worktree
branched from the old mainline tip is no longer at the front of `main`. A second apply is a no-op
(the change is already present) and says so.

### `transcription-path-touched` — Transcription Block, path touched

Only in `fixture-backend`. Fast-forwards or replays its remote's `main` to include a commit that
changes `contracts/fixture-api.json` — the exact path the bundled fixture-web breakdown Card
transcribes. Exercises the Transcription Block: a Card that names a source path whose content has
moved since the Card was authored.

### `mainline-conflict` — Mainline Conflict merge test

Fast-forwards or replays the remote's `main` to include a commit that changes `conflict.txt`'s
line, in every working repo by default. On its own this only moves the remote; combine with
`conflicting-branch` (below) to actually produce a conflicting merge. Its clean verdict from a
rehearsal Night is only as current as the clone at the moment the Night ran `git fetch` — a later
`mainline-conflict` apply (fast-forward or replay) can invalidate an already-reported clean
verdict, which is the point of the scenario.

### `predecessor-merged --branch B` — divergent predecessor, already landed

Merges branch `B` (left behind in a working clone by a rehearsal Night's Worktree) into the
remote's `main` with a `--no-ff` merge commit, via a scratch clone under the tree so the
persistent working clone is untouched. `--repo` restricts which repos get the merge — a merge
applied only to a subset stands in for "the predecessor landed in the backend but not yet in the
web repo." Refuses if `B` does not exist in a named repo; with no `--repo`, defaults to every
working repo where `B` exists and silently skips the rest.

### `conflicting-branch --branch B --repo R` — divergence at dispatch

Creates branch `B` in the working clone for repo `R`, forked from `R`'s remote `main` **as it is
right now** — before this apply touches it — with one commit that changes `conflict.txt` to a
different line than the `mainline-conflict` scenario commit does. It then applies
`mainline-conflict` to `R`'s remote `main` (fast-forward or replay, per *Composing scenarios*), on
top of whatever earlier scenarios already did to that remote. Merging `B` into the now-moved
`main` conflicts on `conflict.txt` no matter what ran before it, so a rehearsal Night that
dispatches against a pre-existing conflicting branch sees a real Mainline Conflict at dispatch
time, not a fixture pretending to be one. Refuses (nothing changed — no branch created, remote
untouched) if `B` already exists in `R`'s clone, or if applying `mainline-conflict` to `R`'s
current `main` would itself conflict. Requires exactly one `--repo`.

### `predecessor-unmerged` — negative control

Changes nothing. Verifies `B` is not an ancestor of the remote's `main` in each targeted repo
(`--repo`, default every working repo where `B` exists) and reports it — the negative control for
`predecessor-merged`, confirming a scenario wasn't already (accidentally) applied.

## Checking a tree

```sh
python3 scripts/rehearsal-fixtures/rehearsal_fixtures.py check --root DIR --project ID
```

Read-only. Verifies the tree is marked, every repo (bare remote + clone) exists, each clone's
`origin` points at its own bare remote, every spec story/goal path exists in the Spec Source at
HEAD, and every scenario ref exists where it should. Prints `PASS`/`FAIL` per assertion and exits
0 only if everything passed.

## Protected Paths refusal

`fixture-backend`'s protected path is `migrations/`. Only a Card's own repository's
`protected_paths` are checked — the engine never reads another repository's — so exercising this
refusal needs a **`fixture-backend`** Card, not a fixture-web (or any other repository's) one. A
Card's declared scope for this check is not read from its authored Contracts: it is read from the
`**Scope:**` line of the Card's Managed Block on the board (the Readiness Check reconciles the
board's own copy), so give a `fixture-backend` Card's Managed Block a `**Scope:**` line naming a
path under `migrations/` — the engine should refuse to dispatch it. This tool does not create that
Card or its Managed Block itself; it only ships the repo layout the refusal test needs.

## Running the unit tests

```sh
python3 -m unittest discover -s scripts/rehearsal-fixtures/tests -v
```

Fully offline — real git operations against tempdirs, no network, no Linear, no Keychain.
`git 2.38` or later is required (matches the repo-wide local-git minimum); the `conflicting-branch`
test additionally uses `git merge-tree --write-tree`. CI
(`.github/workflows/rehearsal-fixtures.yml`) runs only this.
