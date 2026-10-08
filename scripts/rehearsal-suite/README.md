# Rehearsal scenario suite (P15.3)

`rehearsal_suite.py` runs scripted end-to-end rehearsal Nights and asserts, after each, only what
`../yellowhammer-spec/docs/tech/system-overview.md` → *What a story may assert against a rehearsal
Night* allows: route resolution, Repo Lanes and Worktrees, the predecessor-ancestry gate, the per-Project
Bounds' arithmetic, Lease claim/expiry/Reclaim, Protected Paths refusal, Outbox idempotency and replay
after a killed run, Card state transitions and the Night Card lifecycle. It never asserts anything a
model would have authored (diffs, review verdicts, Architectural Briefs, authored Definitions of Done,
conflict resolution), the engine-run Check, push, pull request creation or body, or attempt-completion
behaviour on crash and kill — a fixture green is not a green.

Every Night is a real rehearsal Night: the real `yh` Acts (`--force --rehearsal`), real Linear writes to
the scratch team, real Orca ADE Worktrees, the one real Ledger. It never dispatches an agent CLI, never
pushes and never opens a pull request.

```sh
xcodebuild -project Yellowhammer.xcodeproj -scheme Yellowhammer -derivedDataPath .build/app build
python3 scripts/rehearsal-suite/rehearsal_suite.py run \
    --app .build/app/Build/Products/Debug/Yellowhammer.app --team YLH
```

`--board-connection NAME` picks the Board Connection the suite runs against (default: the sole Board Connection;
none, or several without the flag, is refused); `run` and `teardown` take it, and so does `release_gate.py`.
`--code-hosting-connection NAME` picks the Code Hosting Connection the rehearsal Projects select (default: the sole
entry in `config.toml`'s `[code_hosting.github.connections]` registry; none, or several without the flag, is refused).
`run` and `release_gate.py record` take it.
`--scenario N` (repeatable) runs a subset; `list` prints the scenarios. Exit codes: `0` every selected
scenario passed, `1` a scenario failed, `2` the suite could not be set up (nothing was run). Logs, every
`yh` invocation's output and a Journal snapshot after every step are left in the work directory it
prints (`--work-directory` to choose one). A full run takes about 45 minutes: scenarios 7 and 8 each
wait out a real ten-minute Lease TTL.

## Prerequisites (checked before anything runs)

- A built `Yellowhammer.app` with `yh` in `Contents/MacOS`.
- **Orca ADE** running (`orca status` reports the runtime ready).
- The **scratch Linear environment** (P15.1, `scripts/scratch-linear/README.md`): the scratch workspace's App
  Installation is registered in `config.toml` (token pair in Keychain item `linear-<name>`); the scratch
  team exists and the app is a member of it. A production installation may be on the Mac too, as long as
  `--board-connection` names the scratch one.
- A **Code Hosting Connection** in `config.toml`'s registry (`[code_hosting.github.connections.<name>]`).
  Each rehearsal Project selects one (`[code_hosting] connection`), so the registry must hold the one the suite
  picks. Connect one with `yh setup --install-github`. Its token is never used: a rehearsal Night never pushes.
- An **Operator credential** — a Linear personal API key of a human member of the scratch workspace,
  never the scratch app — for the Operator's own gestures on the board (replying to a question,
  Cancel and reopen, editing a Card's declared scope). The Engine tells a human's comment from its own
  by `isMe`, so a comment written with the app's credential can never be an answer:

  ```sh
  security find-generic-password -s dev.yellowhammer -a linear-rehearsal-operator >/dev/null && echo present
  security add-generic-password -U -s dev.yellowhammer -a linear-rehearsal-operator -w '<personal-api-key>'
  ```

- A **passing Probe Result** in the Ledger for the CLI the suite's Routes name (`claude`): route
  resolution is real in rehearsal. `yh probe claude` records one.
- `git` 2.38 or later.

## What it sets up, and what it leaves behind

- **Rehearsal Projects** `rehearsal-suite-a` and `rehearsal-suite-b` in `~/.config/yellowhammer/projects/`
  (`yh` always reads that directory, and rehearsal uses the machine's one real Ledger). The first run
  creates each with `yh setup --init --board-connection <name> --code-hosting-connection <name> --linear-team <team> --skip-github-check` (the fixture
  repositories have a local bare repository as `origin` and no GitHub token, and a rehearsal Night never pushes), which creates its scratch Linear project
  and provisions the team; no LaunchAgent is ever installed (`--install-jobs` is never passed). Later runs
  reuse them. Before every scenario the suite rewrites the Project file (keeping its `[board.linear]` table, `installation` and `project`, and its `[code_hosting]` `connection`)
  with that scenario's `[limits]`, `check` commands and Protected Paths, and a Routing Table override of
  `claude/sonnet/medium` with fallback `claude/opus/high` — Verification never runs on a Route that wrote
  the Cycle's code, so a single-Route table could never land. **These are real Projects, not sandboxed
  ones**: they show up in the app and in `yh validate` like any other Project, and a routine
  `yh setup --install-jobs` run on this machine would install LaunchAgents for them and schedule real,
  non-rehearsal Nights against the fixture repos. See **Teardown** below.
- **Fixture trees** under `--root` (default `~/Library/Caches/dev.yellowhammer/rehearsal-suite`), built
  with `scripts/rehearsal-fixtures/rehearsal_fixtures.py` at the same paths every run, and registered
  with Orca ADE (`orca repo add`) — Orca refuses a Worktree in a repository it does not know.
- **Reset before every scenario**, per Project: every Orca Worktree of its fixture repositories is
  removed (`orca worktree rm --force`), its scratch issues are archived and its Journal deleted
  (`scripts/scratch-linear/scratch_linear.py reset`), and its fixture tree is rebuilt.
- Scenario 13 writes two conflicting Project files and removes them when it ends, pass or fail.

## Teardown

```sh
python3 scripts/rehearsal-suite/rehearsal_suite.py teardown --app .build/app/Build/Products/Debug/Yellowhammer.app --team YLH
```

Removes everything a suite run leaves on the machine for `rehearsal-suite-a` and `rehearsal-suite-b`, so
a later `yh setup --install-jobs` can never pick them up. Per Project, in order: (1) its non-primary Orca
Worktrees, then its scratch Linear issues and Journal (`scratch_linear.py reset`); (2) `yh project remove
<id> --yes`, which unloads/deletes any LaunchAgents, its Act logs, and `projects/<id>.toml`; (3) its
fixture repositories' Orca ADE registrations (matched by the setup's resolved path falling under
`--root/<id>`, never by name); (4) its Linear project, trashed (`projectDelete`, restorable — Linear
deprecated `projectArchive` in its favor); (5) its fixture tree under `--root`. `--root` itself is removed
at the end if it is then empty. The scratch team's own provisioning (its `Blocked` workflow state and the
rest) is left — it is shared across every Project on the team, not owned by any one of them.

Every step is idempotent: a step whose target is already gone is reported and skipped, not treated as a
failure, so re-running `teardown` after a partial failure (network blip, a step interrupted) finishes the
job. A missing Project file skips the scratch Linear reset and `yh project remove` for that Project (there
is no `[board.linear] project` to read and no Project to remove) but still unregisters its Orca setups and deletes
its fixture tree. `--dry-run` performs every read-only lookup (Project files, Orca Worktrees, Orca setups,
fixture directories) and prints exactly what each step would do, sending no mutation and deleting nothing.

`projects/<id>.toml` is the only record of a Project's `[board.linear] project`, and step 2 deletes it — so a
step-1 or step-2 failure stops that Project's teardown right there (steps 3-5 do not run) and keeps the
Project file, so a re-run can read it again and finish the job. If step 4 (`projectDelete`)
fails after step 2 already succeeded, the Project file is gone by then; the failure message names the
Linear project id so the Operator can trash it by hand.

Preflight (a built `yh`, Orca ready, no `yh` process running for a suite Project, the installation
resolves) fails fast with nothing changed. Otherwise a per-Project failure is recorded and teardown moves
on to the next Project; the command prints a summary and exits `0` only if every step for every Project
succeeded, `1` if anything failed, `2` if preflight itself failed.

## Nights

A Night is the calendar date of its `night_start`, and a second Act on a date whose Night is closed
still belongs to that closed Night. Every Act the suite runs therefore names its Night with the
rehearsal-only `--night YYYY-MM-DD`: Night 1 of a scenario is thirty days before today, Night 2 the day
after, and so on. They are past dates, so each land Act closes its Night. Only the Night's identity
moves; Leases, heartbeats and every timestamp stay on the wall clock.

## Fixtures and gestures

Result files come from the fixtures bundled in the Engine (`--result-fixture <pass>=<fixture>`), a
Card-scoped `--result-fixture <pass>@<card issue id>=<fixture>` where one Card must answer differently
from its lane, and Force authoring (`yh author --feature <name>`) where a Night must author a Feature
under a name of its own. A Feature Branch a rehearsal Night never committed to is contained in its
mainline, which the ancestry gate reads as merged: where a scenario needs the predecessor *unmerged*,
the suite commits a stand-in change in the Feature's Worktree after the land Act, standing in for the
work a real Night's worker would have committed. `rehearsal_fixtures.py apply predecessor-merged`
stands in for the Operator merging pull requests; `transcription-path-touched` for another contributor
moving a transcribed contract.

The Operator's board gestures use the Operator credential: a threaded reply to the Engine's question
comment, moving a Card to the team's shelved state and back to Todo, and declaring a Card's scope
with a `**Scope:**` line in its Managed Block — replacing the one the Engine rendered, or adding it
to a freshly authored Card's block, which carries only its Architectural Brief and Definition of Done.

## Scenarios

Every scenario starts from a reset Project. "Journal" means a read-only snapshot taken after the step.

1. **Idle first Night.** `yh rehearse` with `selection=selection-no-selectable-feature`. The Night is
   closed with verdict `idle`; `AuthoringNoWorkAvailable` is recorded; build and land are `ActIdle`
   (`no_feature_in_flight`); no Feature, Card or Worktree exists; the Night Card was opened and completed
   on the board. *Stories:* `feature-authoring/select-the-next-feature`, `shift-scheduling/open-and-close-the-night-card`.
2. **First Night authoring Feature 1 across three repos.** `yh rehearse` with the three-repository
   selection and breakdown fixtures. One Feature and its Cards exist as native sub-issues of the Feature
   Issue; the Feature Branch is `yh-<project>-<feature>`; exactly one Worktree is held per repository,
   whose checkout is on that branch; every Card is Done; every pass was answered from a fixture and no
   agent CLI process was spawned; each lane's push and open-pull-request steps stop at the rehearsal
   boundary; no bare remote carries the Feature Branch; the Cycle lands and the Night closes. *Stories:* `feature-authoring/author-the-cycle-and-card-dag`, `graph-execution/allocate-a-worktree-per-graph-and-repo`, `graph-execution/run-a-card`.
3. **Quiet Night: predecessor not merged; then merged; then partially merged.** Night 1 authors,
   builds and lands Feature 1 in two repositories; the suite commits stand-in work on its branches.
   Night 2 is quiet: `AuthoringPredecessorNotLanded` names both repositories and nothing is selected.
   Both branches are merged; Night 3 authors Feature 2 (Force authoring), builds and lands it; the suite
   commits stand-in work and merges Feature 2 in `fixture-backend` only. Night 4 is quiet naming only
   `fixture-web`, and records `fixture-backend` as landed. *Stories:* `feature-authoring/select-the-next-feature`, `landing/announce-a-partial-landing`.
4. **Mid-lane block with a Partial Landing announcement rendered.** Three repositories, three Cards in
   the `fixture-backend` lane, `attempts_per_work_card = 1`; the lane's middle Card answers its worker pass
   with `worker-failed`. It ends Blocked, a lane hole is recorded, and the Card after it still runs to
   Done. Land: the Cycle lands, is returned rather than archived, and the Feature Issue's Managed Block
   on the board leads with `partial · … · 1 blocked` and names the blocked Card Blocked by its
   title. *Stories:* `graph-execution/handle-a-block-mid-graph`, `landing/announce-a-partial-landing`.
5. **Waiting on You answered before landing, and after landing (banked).** (a) The Card's worker asks
   (`worker-question`); it is Waiting on You with a recorded question; the Operator replies to the
   question comment; the next build Act records an `answer`, acknowledges it with "It runs on the next
   build Act.", and runs the Card to Done. (b) After a reset: the Card asks and the Night lands; the suite
   commits stand-in work; the Operator replies; the next Night's author Act banks the reply
   (`WaitingOnYouReplyBanked`, a `banked_reply` row stamped with that Night and each repository's
   mainline commit), acknowledges it with "Nothing runs; it is recorded and travels with the Card into
   Adoption.", and the Card stays Waiting on You. *Stories:* `bounds/escalate-a-question-to-the-operator`.
6. **`overdue_nights_max` firing with a value of 1.** The only Card asks on Night 1 and nobody
   answers; the suite commits stand-in work so the Feature stays in flight. Night 2 counts one unanswered
   Night and blocks nothing; Night 3 fires `CardUnansweredBoundFired` and the Card is Blocked under Block
   Reason `reply overdue` on the board, still assigned to the Operator. *Stories:* `bounds/bound-unanswered-nights`.
7. **Engine invocation killed mid-Card, then reclaimed.** `fixture-backend`'s Check holds once; the suite
   waits for it to start and kills the `yh build` holding the Card Lease. The Card is In Progress with an
   open Attempt. After the ten-minute TTL, the next build Act reclaims the Act Lease and the Card Lease,
   ends the Attempt Crashed-Unknown (consumed, Route not excluded), returns the Card to Todo and runs it
   to Done in that same Act. Nothing the killed run left was recorded as if it were complete. *Stories:* `loop-state/claim-and-heartbeat-a-run-lease`, `loop-state/reclaim-an-expired-lease`.
8. **Outbox replay after a killed run.** The author Act runs with `YH_REHEARSAL_OUTBOX_KILL=group:1`: it
   kills itself right after Linear applied the first write of the authoring group and before the Journal
   recorded it. After the TTL, the next author Act replays the group: the pending entries become applied,
   the Feature is authored, and the board holds exactly one issue per authored object — no duplicate. *Stories:* `board-projection/write-board-updates-through-the-outbox`.
9. **Protected Path refusal.** `fixture-backend` protects `migrations/`. After authoring, the Operator
   declares the first `fixture-backend` Card's scope as `migrations/0002_fixture.sql`. The build Act
   refuses it (`ProtectedPathRefused`), moves it to Waiting on You with no Attempt recorded and nothing
   dispatched for it, posts the refusal naming the limitation, and the lane runs its next Card. *Stories:* `bounds/refuse-protected-paths-before-dispatch`.
10. **Divergence at dispatch; Adoption success and refusal.** Feature 1 in two repositories; its
    `fixture-backend` Card asks (`worker-question`), and `transcription-path-touched` moves the contract its
    `fixture-web` Card transcribed. The build Act leaves the backend Card Waiting on You and diverges the
    web Card (`CardDiverged`, Waiting on You under `divergence`, no Attempt). Night 2 (Force authoring
    Feature 2, `selection-selected-adopting`): the merge closure takes Feature 1 out of flight and
    auto-Blocks both Cards, carrying them forward; the backend Card is adopted (`CardAdopted`, now in
    Feature 2's Cycle) and, its Attempt budget untouched by asking, runs to Done; the web Card's Adoption
    is refused (`AdoptionRefused`, back to Waiting on You under `divergence`, `failed_adoptions` 1). An
    adopted Card keeps the Attempts it spent, so a Card that had failed its last Attempt would Block again. *Stories:* `board-projection/check-card-readiness-at-dispatch`, `feature-authoring/author-the-cycle-and-card-dag`.
11. **Shelved Card and reopen.** After authoring two Cards, the Operator shelves the `fixture-web` Card;
    the build Act records `CardShelved`, does not run it, and runs the other. The Operator moves it
    back to Todo; the next build Act records `CardReopened`, restores its state and runs it to Done. *Stories:* `board-projection/read-board-changes-by-delta`.
12. **Two Projects concurrently on one Mac sharing the scratch team.** Projects A and B rehearse the same
    Night at the same time. Both finish; each Journal names only its own Project; every issue id either
    Journal holds is in that Project's Linear project and in neither the other Journal nor the other
    Linear project; the two Journals share no run id; every Worktree either Journal holds is a checkout
    of that Project's own fixture repositories (Orca places Worktrees under its own workspace directory,
    so this is read from each checkout's git common directory, not its path). *Stories:* `graph-execution/allocate-a-worktree-per-graph-and-repo`.
13. **Two conflicting Projects plus one valid Project.** Two Project files declare the same repository.
    `yh validate` fails both, naming the conflict, and passes the valid one; the valid Project's
    rehearsal Night runs; an Act for a conflicting Project is refused at load and creates no Journal. *Stories:* `shift-scheduling/diagnose-the-installation`.

## Release gate (P15.4)

`release_gate.py` turns a suite run into release evidence, and that evidence into a pass/fail a
release checklist can act on (`doc/release-checklist.md`):

```sh
python3 scripts/rehearsal-suite/release_gate.py record \
    --app .build/app/Build/Products/Debug/Yellowhammer.app --team YLH \
    --evidence-directory .build/release-evidence
python3 scripts/rehearsal-suite/release_gate.py check --evidence-directory .build/release-evidence
```

`record` runs the suite (its own `--work-directory` nested inside `--evidence-directory`) and writes
`suite.log`, a `journals/` copy of every Journal snapshot the run left behind, `night-cards.md`
(every Night Card the run's Journals hold, linked through the scratch installation's credential — falling back
to the bare issue id if the fetch fails), and `verdict.json` (commit sha, tree cleanliness, the
scenarios selected, and a PASS/FAIL per scenario). `check` exits 0 only when `verdict.json` says
every scenario passed, the tree was clean, and the recorded commit matches `--commit` (default
`git rev-parse HEAD`) — a failed scenario, a subset run, or a stale evidence directory all fail it.

There is no self-hosted runner yet, so this step is a manual release-checklist item today. The
dormant `.github/workflows/rehearsal-suite-live.yml` (`workflow_dispatch` only) is ready to take it
over once a self-hosted Apple Silicon runner with Orca ADE and the scratch credentials is registered.

## Running the unit tests

```sh
python3 -m unittest discover -s scripts/rehearsal-suite/tests -v
```

Fully offline: fake transports, fake processes and synthetic Journals. CI
(`.github/workflows/rehearsal-suite.yml`) runs only these; the suite itself needs a Mac with Orca ADE,
the scratch credentials and the network.
