# Refactor the Feature Branch to the name Orca ADE reports — roadmap

This roadmap records the Feature Branch Orca ADE actually creates, which may carry a `<prefix>/`.
It replaces the name the engine computes, and makes a branch-name collision halt the build Act. It
fixes [#318](https://github.com/summerhammer/yellowhammer/issues/318). It is separate from
`implementation-roadmap.md` and does not renumber it; that file gets one line linking here, in
B1.1's first commit.

**Spec** at `bd1baea`, *docs(spec): Feature Branch prefix and lost-Worktree recovery — OQ123 ruled*.

- Rulings:
  - risks.md → A12, which carries the naming rule.
  - *Lost Worktree Recovery Ruling — 2026-10-05* (OQ123), items (a)5–6 and (c). Item (a)1–4, the pin
    and recovery, is [#325](https://github.com/summerhammer/yellowhammer/issues/325) and **out of
    scope**.
- Stories:
  - `graph-execution/allocate-a-worktree-per-graph-and-repo`, the main contract: ACs on lines 40–74.
  - `loop-state/reconcile-worktrees-at-act-start`.
- Glossary: *Feature Branch*, *Worktree*, *Exception Notification* (line 840: "a collision is a cause
  of *halted*").

Read the ruling and the story before each step.

## Why: what happened and what was found

- **The failure.** On the first real Night (2026-10-04/05), every build Act ended `ActIncomplete`
  with "Orca ADE could not create branch 'yh-yellowhammer-…' in yellowhammer; it created
  'rozd/yh-yellowhammer-…' instead". `WorktreeAllocator` treated any difference between the requested
  and the reported branch as `WorktreeAllocationError.nameCollision`, so no Card ran.
- **The cause is an Orca ADE setting.** It is `settings.branchPrefix` (`"git-username"`) with
  `settings.branchPrefixCustom` (`""`). Both live in
  `~/Library/Application Support/orca/profiles/local-default/orca-data.json`, not in the top-level
  `orca/*.json`. The git username is **per repo** (`repos[].gitUsername`, `rozd` here), so one Feature
  can get different prefixes in different repos.
- **The setting can't be read through a supported interface.** The `orca` CLI has no settings or
  config command. `orca repo show --json` exposes `gitUsername` but not whether the prefix is on.
  Reading `orca-data.json` would rely on a vendor's internal format, so detecting the prefix in
  `yh doctor` was rejected.
- **Orca does return the branch it used.** `orca worktree create --json` returns
  `result.worktree.branch` (`refs/heads/rozd/yh-…`), and `OrcaADEAdapter` strips only `refs/heads/`.
  It gives no separate prefix field and no reason for the difference.
- **Live probe, 2026-10-05**, a temporary worktree `yh-probe-branchprefix-…` in the registered
  yellowhammer repo, removed afterwards:
  - The reported branch was `rozd/yh-probe-…`. The Worktree's name and path stayed unprefixed.
  - After `git branch -m`, the worktree's HEAD followed the rename.
  - `orca worktree list` kept reporting the **old** name: Orca stores the branch name itself.
  - `orca worktree rm --force` still succeeded. It runs asynchronously (`removing: true`) and deleted
    the renamed branch, i.e. the branch actually checked out.
  - `git branch -m` onto an existing name fails.

  The sponsor rejected renaming the branch back: Yellowhammer never renames it.
- **Orca ADE deletes the local branch on every Worktree removal** (spec re-probe, Orca ADE 1.4.220).
  After release, only the pushed remote branch survives. This matters for every reader that runs after
  release.
- **Nothing in Sources reads branches from Orca's list:** `Workspace.worktrees(repositoryPath:)` has no
  caller. Orca storing a stale name there is harmless to the engine.
- **Today the branch is stored once per Feature.** It goes in `feature.branch`, computed at authoring
  as `FeatureBranch(project:feature:)` before any Worktree exists. This was a modelling shortcut that
  held only while the name was derived and identical across repos. The spec already treats a Feature
  Branch as one per (Feature, repo).

## What changes

- **Two names, two types.** The **Worktree name** is what Yellowhammer requests: `yh-<project>-<feature>`,
  slash-free. The **Feature Branch** is what Orca ADE reports: the Worktree name, optionally preceded by
  `<prefix>/`, where the prefix may contain `/`.
  - New `Domain.WorktreeName` takes over the derivation and the sanitising.
  - `FeatureBranch` becomes a plain recorded value.
- **Journal (`journal-schema-3` → `-4`, edited in place, pre-1.0):**
  - `feature.branch` → `feature.worktree_name`, the requested name.
  - `feature_repository` gains `branch`, the recorded Feature Branch, set at first allocation and never
    changed.
- **Allocation rules, exactly one applies:**
  - A branch is already recorded for (Feature, repo): the reported branch must equal it exactly.
  - Nothing is recorded: the reported branch must equal the Worktree name, or end with `/` + the
    Worktree name.
  - Anything else is a collision. The Worktree is removed and nothing is written.
- **Every consumer resolves the branch per (Feature, repo).** That covers build, land, the predecessor
  gate, verification and Project removal. Where nothing is recorded, they fall back to the Worktree
  name.
- **A collision halts the build Act** (layer 2): Cards stay Todo, no Attempt, no Block Reason. The
  halted notice goes out once per Project per Night; later Acts only update the Night Card.
- **CI and scripts:**
  - `check_spec_line.py` recognises `yh-` as the last path segment of the head ref.
  - The rehearsal suite reads the recorded branch.

## Local choices (this repo's, not the spec's)

- **Storage on `feature_repository`, not the `worktree` row** (user decision, 2026-10-05).
  - A (Feature, repo) pair can have several `worktree` rows (lost, then re-allocated), and released rows
    have no dedicated query.
  - `feature_repository` has exactly one row per pair, which authoring already fills. "Fixed once
    recorded" and reads after release are then a single lookup.
  - The story's wording "recorded with the Worktree's id and path" is met by writing both in one
    transaction.
- **The fallback to the Worktree name** where no branch is recorded (the lane was never allocated) is
  deliberate. The ref cannot exist, so `AncestryTester` and `MergeTester`'s three probes (local name,
  `refs/heads/`, `refs/remotes/origin/`) fail exactly as they do today, giving not-pushed /
  not-ancestor. Do not "fix" it.
- **`recordFeatureBranch` upserts into `feature_repository`,** so an allocated repo counts as *touched*
  for the Pulse (`touchedRepositories`) and for the gate's N. This is intended.
- **Collision verdict.** The collision appends `actIncomplete`, so the Night verdict is `halted`
  (`NightSummary+Verdict.swift:53`), like the Linear-authorization halt. A Night that recovers later
  still closes `halted`. The spec rules the notification, not the verdict; see *Spec gaps*.
- **`check_spec_line.py` loosening.** `feature/yh-thing` becomes exempt from the `Spec:` line, because
  it can't be told apart from an Orca custom prefix. Note the trade-off in the PR body.

## Key code references

- **Allocation:**
  - `Packages/YellowhammerKit/Sources/Engine/WorktreeAllocator.swift`: `allocate` and `nameCollision`.
  - The only build caller is `Engine/BuildAct.swift:278-308` (`allocateWorktree`), which turns errors
    into strings at `:306`.
- **Adapter:** `Sources/OrcaADEAdapter/OrcaADEAdapter.swift`, `workspaceWorktree` /
  `stripRefsHeadsPrefix`. No change.
- **Where the name is derived:** `Sources/Domain/FeatureBranch.swift`.
- **Journal:**
  - `Journal/JournalMigrations.swift:14` (`schemaIdentifier`), `JournalMigrations+Schema.swift:56`
    (`feature.branch`), `JournalMigrations+SchemaFeatureFlow.swift:151` (`feature_repository`).
  - `JournalStore+Authoring.swift:122` (authoring writes the name), `JournalStore+Features.swift:19,95,118`
    (`FeatureRecord.branch`, `recordFeatureBranch`, decode).
  - `JournalStore+FeatureLandings.swift:72` (`insertFeatureRepositories`), `Worktree.swift`
    (`WorktreeRecord`, `recordWorktree`, `heldWorktree`, `worktrees(featureID:)`).
- **The 31 consumer sites, by group:**
  - Build: `BuildAct.swift:135`, `WorktreeReconciler*.swift`, `CardRun+Frame.swift:127`,
    `CardRun+Reset.swift:33`, `CardRun+Passes.swift:224`, `AttemptResetting.swift`,
    `Repositories/WorktreeCommitter*.swift`, `WIPCommitMessage.swift`.
  - Land: `FeatureBranchLaneMergeTest.swift:41`, `FeatureBranchLanePush.swift:30,66`,
    `FeatureBranchPullRequest.swift:49,276` (PR head and `{branch}` title token),
    `LandAct+PushReport.swift:41,57`, `Repositories/FeatureBranchPusher.swift`.
  - Gate: `PredecessorAncestryGate.swift:159,183`; `Repositories/AncestryTester.swift:79-104` and
    `MergeTester.swift:97-122` take **one** branch for all repos.
  - Verification: `FeatureVerification+Dispatch.swift:123,137` (per-repo entry, and the single-name
    title).
  - Removal: `EngineCommand/ProjectRemoval+Worktrees.swift:91,104-167`, `ProjectRemoveCommand.swift:55`.
- **Halt and notification (layer 2):**
  - `EngineInvocation.swift:282-291` (the `runUnderLease` catch).
  - `EngineInvocation+ExceptionNotification.swift`: `notifyHalted` :82, the once-per-Night pattern in
    `notifyLinearAuthorizationHalted` :103-114, `recordHaltedComment` :131, `collapsed` :167 (200
    characters).
  - `Domain/ExceptionNotification.swift` (`.halted(reason:)`).
  - Journal event wiring: `JournalEventType.swift`, `JournalEvent+Payload.swift`, `+Type.swift`,
    `+Decoding.swift`.
  - `NightSummary+Exceptions.swift:106` (`exceptionLines`), `NightSummary+Verdict.swift:53`.
- **Fixtures and scripts:**
  - `YellowhammerUITests/Fixtures/archive.db`, regenerated with
    `YH_WRITE_UI_TEST_JOURNAL=1 swift test --package-path Packages/YellowhammerKit --filter writeUITestJournal`.
  - Schema-literal tests: `NightTests.swift:32`, `LinearWorkspaceTests.swift:25,27`,
    `ActLeaseTests.swift:38,41`.
  - CI: `scripts/ci/check_spec_line.py:34,41` and `tests/test_check_spec_line.py:215-220`.
  - Rehearsal suite: `scripts/rehearsal-suite/scenarios.py:129-133,166,192`, `suite_env.py:502`,
    `tests/test_suite_env.py:211-222`, `scripts/rehearsal-fixtures/rehearsal_fixtures.py:97`.
- **Test volume:**
  - About 30 `recordFeatureBranch(featureID:branch:)` calls in 18 test files.
  - 47 `recordWorktree(` calls in 20 files; leave them unchanged if `recordWorktree` gains no required
    parameter.
  - The raw INSERT with `branch` in `PredecessorAncestryGateFixtures.swift:79`; the assertions in
    `JournalStoreFeaturesTests.swift:69,76` and `AuthoringTransactionTests.swift:63`.

## Every step

- **Start state.** The working tree holds an uncommitted, superseded rename fix: `WorktreeAllocator.swift`
  modified, plus `Tests/EngineCommandTests/WorktreeAllocatorBranchPrefixTests.swift`. Before B1.1 the
  lead runs `git checkout -- Packages/YellowhammerKit/Sources/Engine/WorktreeAllocator.swift` and
  deletes the test file. Briefs ban `git restore`, so the sidekick must not inherit `isPrefixed` or
  `branch -m`.
- **Names.** Glossary terms verbatim: Feature Branch, Worktree, Repo Lane, Exception Notification,
  Night Card. Vendors are named in tests (Orca ADE), never the Port.
- **Models.**
  - Recommended per step below. Claude: Fable > Opus > Sonnet. Codex: Astra > Sol > Terra. Gemini:
    Flash 3.8 is the fast, cheap tier.
  - Pick one family per step. The lead (planning, review, commits) stays on the strongest model in the
    session.
  - The sidekick dial follows `conventions/agents.md` and project memory: Sonnet for cross-module Swift
    briefs, and slice wide briefs, resuming the same agent with SendMessage.
- **Sidekick briefs** ban `git checkout`, `git restore`, `git stash`, `cd &&` chains and new
  `swiftlint:disable`. The lead verifies every lint and test claim, and writes concurrency and actor
  tests itself.
- **Done when**, in addition to each step's line:
  - `swift test --package-path Packages/YellowhammerKit` is green. Re-run the known whole-suite flakes
    (WorktreeReconcilerContinued fencing, CardRunCommitMessage) in isolation.
  - The app builds.
  - `swiftlint lint --strict` reports 0 violations.
  - `python3 scripts/ci/check_module_boundaries.py` passes.
  - The cited ACs are listed met or explicitly not met.
  - Commits and PRs carry `Spec: graph-execution/allocate-a-worktree-per-graph-and-repo @ bd1baea`
    (`/spec-cite`).
- **Stacking.** Layer 1 is B1.1–B1.4 as commits in one PR (`fix(engine): record the Feature Branch Orca
  ADE reports`, "Refs #318"). Layer 2 is B2.1 (`fix(engine): a Worktree branch-name collision halts the
  build Act`, "Closes #318"), added with `gh stack add` on top.
  - `git fetch` first.
  - Check `gh stack view` for an open stack; a new layer goes on top of it.
  - After `gh stack submit --auto`, fix the PR title and body with `gh pr edit`.
  - Mark `[x]` in its own commit on that layer.
  - Nothing is pushed or submitted without the user's go-ahead.

---

## Layer 1 — Record the Feature Branch Orca ADE reports

### [x] B1.1 Domain, Journal and allocation

**Status** — done 2026-10-05 (`fd410a4`).
- **Landed:**
  - `WorktreeName` and a plain `FeatureBranch`.
  - `journal-schema-4` (`feature.worktree_name`, `feature_repository.branch`).
  - `featureBranch` / `featureBranches` / `recordFeatureBranch`, with the new
    `JournalError.featureBranchConflict`; `recordWorktree(…, featureBranch:)` writes both in one
    transaction.
  - The allocator's two exclusive rules, `WorktreeAllocator.accepts`. A Journal conflict raised
    between the read and the write also removes the Worktree and throws `nameCollision`, now
    `(repository:requested:reported:recorded:)`.
  - `archive.db` regenerated.
- **Stubs left for B1.2:**
  - Sites with a repo in scope use `JournalStore.resolvedFeatureBranch(feature:repository:)` (recorded,
    else the Worktree name).
  - Reconcile, the predecessor gate and the verification title use the Worktree name and carry a
    `// B1.2` marker.
- **Pulled forward from B1.3:**
  - The mechanical rename of the ~30 test calls, the raw `INSERT` and the assertions, which the suite
    needed to compile.
  - A pure test of the acceptance rule.
  - B1.3 still owns the git-backed allocator cases and the two-repo tester tests.
- **ACs met:**
  - Lines 40–49 (request the slash-free name; record the reported branch with the Worktree's id and
    path).
  - Lines 50–54 (equal, or `/` + name).
  - Lines 55–57 and 65–66 (a recorded branch is fixed; a different one on re-allocation is a
    collision).
  - Their collision outcome: the Worktree is removed and nothing is written. The halt itself is B2.1.
- **Verification:**
  - Full suite green except a `ProcessFencerTests` timing flake under whole-suite load. It passed in
    isolation, as did WorktreeReconcilerContinued and CardRunCommitMessage.
  - The app builds; lint `--strict` reports 0; module boundaries pass.
  - The read-only open refuses `journal-schema-3`.

- **Work**
  - `Domain/WorktreeName.swift`: `WorktreeName` (RawRepresentable, Hashable, Sendable) with
    `init(project:feature:)`, `init(projectID:feature:)` and `sanitize`, moved from `FeatureBranch`.
  - Strip `FeatureBranch` to `init(rawValue:)` / `init(name:)` plus its string-literal conformance, and
    rewrite its doc comment.
  - Schema `-4`:
    - `feature.branch` → `worktree_name`.
    - Add `feature_repository.branch TEXT` (nullable).
    - `FeatureRecord.branch` → `worktreeName: WorktreeName?`.
    - `recordFeatureBranch(featureID:branch:)` → `recordWorktreeName(featureID:worktreeName:)`.
    - Authoring writes `WorktreeName(project:feature:)`.
  - New Journal API:
    - `featureBranch(featureID:repository:) -> FeatureBranch?`
    - `featureBranches(featureID:) -> [String: FeatureBranch]`
    - `recordFeatureBranch(featureID:repository:branch:)`: upserts, sets the branch only when NULL, and
      throws if a different name is already set.
  - `WorktreeAllocator.allocate(featureID:worktreeName:repos:)`:
    - Read the recorded branch **before** calling Orca.
    - Apply the two exclusive rules from *What changes*.
    - On a mismatch, remove the Worktree, then throw `nameCollision`. Write nothing.
    - On success, write `recordWorktree` and `recordFeatureBranch` in one transaction.
    - Rewrite the doc comments and `description`.
  - `BuildAct.allocateWorktree` passes the Worktree name.
  - Bump the schema literals in tests and regenerate `archive.db`.
- **Spec** — story ACs on lines 40–57 and 65–66; glossary *Feature Branch*; A12.
- **Models**
  - Lead: Opus 5.5, High effort. Designs the types and the transaction.
  - Sidekick: Sonnet 5.5, or Codex Sol. Fable or Astra are not needed.
- **Done when**
  - The package compiles with `FeatureRecord.branch` gone; consumers may be stubbed only through
    `featureBranch` lookups, which B1.2 completes.
  - Journal tests cover: set once; same name again is a no-op; a different name throws;
    `featureBranches` reads a released Feature.
  - The app's read-only open accepts `-4` and refuses `-3`.

### [x] B1.2 Consumers resolve the branch per (Feature, repo)

**Status** — done 2026-10-05 (`4cf8e5b`).
- **Landed:**
  - `WorktreeReconciler.reconcile(feature:)` resolves per held record.
  - The testers take `branches: [String: FeatureBranch]`; a repo absent from the map is reported
    indeterminate (ancestry) or untestable (merge) without running git. The `branchName:` overloads
    are gone.
  - The gate uses the new `resolvedFeatureBranches(feature:repositories:)`, which shares the fallback
    with `resolvedFeatureBranch`.
  - Verification carries a per-repo branch, and the title no longer names one.
  - Land, push, PR, Card frame and removal were already per repo in B1.1. Refs under
    `refs/yellowhammer/` take the slashed name unchanged.
- **Done-when:** the `feature.branch` grep and the `B1.2` markers are empty. The full suite is green,
  including WorktreeReconcilerContinued and CardRunCommitMessage. The app builds, lint `--strict`
  reports 0, and module boundaries pass.
- **ACs:** the glossary's per-(Feature, repo) ancestry and merge reads, and the story
  `reconcile-worktrees-at-act-start`'s WIP commit "on the Feature Branch recorded for that
  repository", are met in code. The two-repo, different-prefix tests are B1.3's.

- **Work**
  - Replace every `feature.branch` read with a per-repo lookup, using one shared helper that falls back
    to the Worktree name.
  - **Build:** reconcile and `WorktreeReconciler` per record; `CardRunFrame.branch` from the lookup for
    `card.repository`.
  - **Land:** merge test, push, `hasCompletedWork`, PR head and `{branch}` title, push report.
  - **Testers:** `AncestryTester.evaluateAncestry` and `MergeTester.evaluateMerge` take
    `branches: [String: FeatureBranch]`. Their reports carry per-repo branches.
    `PredecessorAncestryGate` passes `featureBranches`.
  - **Verification:** a per-repo `featureBranch`. Drop the single "(Feature Branch …)" from
    `featureTitle`.
  - **`ProjectRemoval+Worktrees`:** per held worktree. Refs under `refs/yellowhammer/{wip,attempts,removed}/`
    accept a slashed name unchanged.
- **Spec** — glossary *Feature Branch* (ancestry gate, merge test); `reconcile-worktrees-at-act-start`.
- **Models**
  - Lead: Opus 5.5, Medium effort. Reviews per-repo correctness at the gate.
  - Sidekick: Sonnet 5.5, or Codex Sol. This is cross-module (Engine, Repositories, EngineCommand), so
    slice it: (a) build path, (b) land path, (c) testers and gate, (d) verification and removal.
- **Done when**
  - `grep -rn "feature.branch\|\.feature\.branch" Packages/YellowhammerKit/Sources` is empty.
  - Each group compiles and its existing tests pass.

### [x] B1.3 Tests

**Status** — done 2026-10-05 (`f031bdc`).
- **Landed:**
  - The mechanical updates (the ~30 calls, the raw `INSERT`, the assertions) were already in B1.1.
  - `WorktreeAllocatorBranchPrefixTests`: a git-backed fake Orca ADE checks out the branch it reports.
    `rozd/yh-x` and `team/rozd/yh-x` are recorded as reported, and no unprefixed ref appears.
    `yh-x-2` and `rozd-yh-x` are collisions: removed with force, nothing recorded. A re-allocation
    reporting `team/` against a recorded `rozd/` is a collision, and the recorded branch is unchanged.
  - `FeatureBranchPrefixTesterTests`: ancestry and merge over two repos with different prefixes. A
    swapped map finds neither branch.
  - `LandActPushTests+Prefix`, `FeatureBranchPullRequestPrefixTests`: the remote gets only the prefixed
    ref; the pull request head and the `{branch}` title token are the prefixed name.
- **ACs:** lines 50–57 and 65–66 (acceptance, fixed once recorded, a different name on re-allocation)
  are met and tested. The existing collision test still passes.
- **Verification:** full suite green (1463 + 82 + 240 + 103 tests). WorktreeReconcilerContinued and
  CardRunCommitMessage also passed in isolation. The app builds, lint `--strict` reports 0, and module
  boundaries pass.

- **Work**
  - Mechanical update of about 30 test calls: `recordWorktreeName` for the requested name, plus
    `recordFeatureBranch(featureID:repository:branch:)` where the test needs a recorded branch.
    Fix the raw INSERT and the two assertions.
  - New `WorktreeAllocatorBranchPrefixTests.swift`, with a git-backed fake Workspace modelled on
    `WorktreeAllocatorLastKnownGoodTests.swift`. Create the Journal fixture inside each `@Test`. Cases:
    - `rozd/yh-x` is recorded as reported, with no rename.
    - `team/rozd/yh-x` is accepted.
    - `yh-x-2` and `rozd-yh-x` are collisions: removed and nothing recorded.
    - A re-allocation that reports a different prefix than the recorded one is a collision.
  - Ancestry and merge with two repos carrying different names.
  - A land push and PR head that use the recorded prefixed name.
- **Spec** — story ACs on lines 50–57 and 65–66 (the collision cases); the existing collision test must
  still pass.
- **Models**
  - Mechanical updates: Gemini Flash 3.8, or Codex Terra, or Sonnet 5.5.
  - New allocator and tester tests: Sonnet 5.5, or Codex Sol.
  - Lead: Opus 5.5, Medium effort, verifies the counts and lint.
- **Done when** — the full suite is green and every case above is present.

### [ ] B1.4 Scripts and CI

- **Work**
  - `check_spec_line.py`: exempt when the head ref's last path segment starts with `yh-`.
    - Tests: `rozd/yh-x` and `feature/yh-thing` are exempt; `my-yh-thing` and `yh` are not.
  - Rehearsal suite:
    - `scenarios.py` reads `feature_repository.branch` and asserts it ends with `/` + the requested
      name, or equals it. Use the recorded name for the checked-out and remote ref checks.
    - `suite_env.py` gets a `feature_repository` reader.
    - Fix the hand-written schema in `tests/test_suite_env.py`.
- **Spec** — glossary *Feature Branch*; CLAUDE.md's `yh-*` PR exemption.
- **Models**
  - Sidekick: Gemini Flash 3.8, or Codex Terra. This is small Python with spelled-out cases.
  - Lead: Opus 5.5, Low effort.
- **Done when**
  - `python3 -m unittest discover scripts/ci/tests` passes.
  - The rehearsal-suite unit tests pass.

**Layer 1 review** — before submitting, run one broad review of the whole layer diff (31 sites), using
Claude Fable 5.1 or Codex Astra. Then fix through another sidekick handoff rather than a lead rewrite.

---

## Layer 2 — A collision halts the build Act

### [ ] B2.1 Collision halt, once-per-Night notification, Night Card

- **Work**
  - **`BuildAct`:**
    - Allocate every runnable lane's Worktree in a sequential **pre-pass**, before any lane runs. A
      collision halts the Act before any Card is touched.
    - Throw a typed `BuildActError.worktreeNameCollision(repository:requested:reported:)` instead of
      turning the error into a string.
  - **New Journal event `worktreeNameCollision`:** repository, requested and reported in the payload,
    wired through the four event files.
  - **`runUnderLease` catch:**
    - Always append the event, then `actIncomplete` (a cause of *halted*).
    - On the first collision event this Night (the `notifyLinearAuthorizationHalted` pattern), run the
      full `notifyHalted`: Night Card comment plus `.halted`.
    - On later Acts, write only the Night Card comment (`recordHaltedComment`) and post nothing.
  - **Reason text,** within 200 characters: the repo, the requested branch, the reported branch, and
    "restore Orca ADE's branch-name prefix setting, or `git branch -m` the branch that holds the name".
    Never suggest `git branch -D` or `orca worktree rm`.
  - A collision line in `NightSummary.exceptionLines`.
- **Spec** — story ACs on lines 67–74; OQ123(c); glossary *Exception Notification* line 840.
- **Models**
  - Lead: Opus 5.5, High effort. Owns the control flow and writes the once-per-Night notification
    tests itself.
  - Sidekick: Sonnet 5.5, or Codex Sol, for the event wiring, the pre-pass and the summary line. Use
    Codex Astra only if the pre-pass reshapes `runLanes`' concurrency beyond a simple loop.
- **Done when** — tests show:
  - A collision runs no Card: Cards stay Todo, no Attempt, no Card Lease, no Block Reason.
  - First Act: one notification. Second Act the same Night: no notification, a new Night Card comment,
    two events.
  - The next Night notifies again.
  - The exception line renders.

### [ ] B2.2 Live check

- **Work**
  - Confirm the scratch Linear environment (`YLH`) is connected; it was torn down 2026-10-03, and the
    user re-connects it.
  - Leave Orca's prefix on and run `yh build --project yellowhammer` in rehearsal mode. Expect:
    - a Worktree on `rozd/yh-…`;
    - `feature_repository.branch` holding that name;
    - the Card starting.
  - Force a collision (a branch already holding the name, or a prefix change between Acts). Expect one
    notification across two Acts and the Cards still Todo.
  - Remove every probe Worktree and branch afterwards.
- **Models** — the lead only, Opus 5.5 or Fable 5.1. Not delegated: it touches real Orca ADE, Linear
  and notifications.
- **Done when** — both outcomes are observed and recorded in the PR.

---

## Spec gaps to raise (do not edit the spec)

- **The verdict for a collision halt.** The spec rules the *halted* notification and "later Acts retry",
  but not whether a Night that recovers mid-Night still closes `halted`. As built, it does: any
  `actIncomplete` makes the verdict `halted`.
- **Unanswered-Nights bound** for a Night whose Acts all halted on a collision. The ruling's *Left
  unruled* lists it; keep today's behaviour.
- **Asynchronous branch deletion** after a purge or release: a re-allocation may see `X-2`. Unruled;
  this is #325's territory.
- **`check_spec_line.py`'s exemption** cannot tell an Orca custom prefix from a human branch named
  `x/yh-…`. This is repo-local, but worth a line if the spec ever names the `yh-*` exemption.
