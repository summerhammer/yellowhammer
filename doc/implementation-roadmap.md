# Yellowhammer — Implementation Roadmap

Built against `../yellowhammer-spec` @ `eea7711` (2026-09-15).

This roadmap lists **what** has to be built and **in what order**. It holds no implementation
advice and makes no architectural decisions. Where the spec leaves a decision open, the roadmap
names it as a **Decision Gate** and says which steps wait on it. It does not pick an answer.

The spec is authoritative. This file quotes no spec content. It points to it by story ID
(`<epic>/<story>`), ADR, DR, OQ or document path. Before you start a step, read the cited story
**and** its epic's `overview.md`. If this roadmap and the spec disagree, the spec wins, and the
disagreement is a defect in this file.

---

## How to read this document

- **Phases** run in order. A phase depends on the phases before it unless it says otherwise.
- **Steps** inside a phase run in the order listed unless marked *(parallel with …)*.
- Each step has:
  - **Work** — what is built, configured or produced.
  - **Spec** — the stories, rulings and documents that define it.
  - **Done when** — how you can check the step is complete.
  - **Agent** — recommended Claude Code implementor model and effort (`Fable 5.1 High`,
    `Fable 5.1 Medium`, `Opus 5 Medium`, `Sonnet 5 Medium`). Open steps only. Fable for steps
    where lease, transaction, ancestry or state-machine correctness is the work; Opus for
    bounded adapters, CLI surfaces and app screens; Sonnet for scripted `[DevOps]` steps. Where a
    step lists `Gemini Flash 3.8 Medium` as an alternative, the work is scripted, templated or a
    thin wrapper over a documented tool, and a cheap model is acceptable.
- **Every acceptance criterion in a cited story is part of "done".** A "Done when" line picks out
  the key checks. It does not replace the story's criteria.
- **DevOps** steps are marked `[DevOps]`. They sit where they are needed in the order, not in a
  separate track.
- **Testing constraint (binding on every step):** assert only what
  `docs/tech/system-overview.md` → *What a story may assert against a rehearsal Night* allows. Never
  assert model-authored content, the engine-run Check against fixtures, push, pull request creation
  or body, or attempt-completion behaviour on crash/kill.

### Phase map

| Phase | Name | Purpose |
|---|---|---|
| 0 | Foundations & delivery pipeline | Repo, CI, lint, test, traceability, local prerequisites |
| 1 | Decision gates | Open decisions to close before the steps that depend on them |
| 2 | Configuration | Machine and per-Project TOML, load-time validation |
| 3 | Local stores | The Journal (per Project) and the Ledger (per machine) |
| 4 | Engine invocation shell | `yh <act> --project <id>`: one Act, then exit |
| 5 | Board: Linear | Identity, provisioning, Outbox, Delta Read, Managed Block, Night Card |
| 6 | Repositories & Worktrees | Local mainline reads, Orca ADE worktrees, reconciliation |
| 7 | Dispatch & Routing | CLI Adapters, Probes, process lifecycle, route resolution |
| 8 | Build Act | Readiness, Protected Paths, the Card loop, Rounds/Attempts, leases |
| 9 | Author Act | Feature selection, ancestry gate, authoring transaction, DoD, briefs |
| 10 | Land Act & Verification | Push, pull requests, merge test, Partial Landing, Verification, archival |
| 11 | Escalation, Adoption & remaining Bounds | Waiting on You, banked replies, Adoption, promotion bounds |
| 12 | Morning report | Night Summary, instrumented rates, roll-up, exception notification |
| 13 | Setup & operations CLI | `yh setup`, scheduled jobs, `yh doctor`, `yh status`, Project removal |
| 14 | Yellowhammer app | The shell: setup, configuration, probes, Journal reading, notifications |
| 15 | Rehearsal environment & end-to-end rehearsal | Scratch Linear team, throwaway repos, full rehearsal Nights |
| 16 | Release engineering & first production Night | Signing, notarization, packaging, install check, go-live |

---

## Phase 0 — Foundations & delivery pipeline

### [x] P0.1 `[DevOps]` Remote repository and branch policy
- **Work**
  - Create the remote repository for `yellowhammer` under the source-control org. The repo has no
    remote yet (see `CLAUDE.md` → Git).
  - Push `main`. Protect `main`: changes arrive by pull request only, and CI must pass.
  - Record the repo's relationship to `../yellowhammer-spec` (a separate repo, read-only from here)
    in the README.
- **Spec** — `CLAUDE.md` → Git; `skill.md` → *The spec is read-only from a consumer repo*.
- **Done when** — `main` is protected on the remote. A direct push to `main` is refused.

### [x] P0.2 `[DevOps]` Pull request template with spec traceability
- **Work**
  - Add a pull request template with a required `Spec: <epic>/<story> @ <spec commit sha>` line.
  - Add a checklist: every acceptance criterion of the cited story is covered, or listed as not
    satisfied with a reason.
  - Add a CI check that fails a pull request whose body has no well-formed `Spec:` line (with an
    explicit exemption marker for non-spec work such as DevOps).
- **Spec** — `skill.md` → *Citing the spec*; `CLAUDE.md` → Git.
- **Done when** — A pull request with no `Spec:` line and no exemption fails CI.

### [x] P0.3 `[DevOps]` Continuous integration pipeline
- **Work**
  - A CI workflow on Apple Silicon macOS runners, on every pull request and on `main`:
    1. Resolve and cache package dependencies.
    2. Lint with SwiftLint (the committed `.swiftlint.yml`), with violations failing the build.
    3. Run the package test suite (`swift test --package-path Packages/YellowhammerKit`).
    4. Build the `Yellowhammer` scheme (Debug), which embeds `yh`.
    5. Check that the built bundle contains `Contents/MacOS/yh` and that `codesign --verify --deep
       --strict` passes on the Debug product.
  - Pin the Xcode and Swift toolchain version used by CI and record it in the README.
  - Publish test results and build logs as CI artifacts.
- **Spec** — `CLAUDE.md` → Local choices (Build, Lint, Testing);
  `docs/tech/investigations/2026-09-13-feasibility-probes.md` → Build and packaging.
- **Done when** — A pull request shows lint, test and build as separate required checks. A lint
  violation, a failing test or a missing `yh` each fail the pipeline.

### [x] P0.4 `[DevOps]` Deployment-target consistency check
- **Work**
  - Add a CI check that `MACOSX_DEPLOYMENT_TARGET` in the Xcode project and `platforms` in
    `Package.swift` are equal. It fails the build when they differ.
- **Spec** — `CLAUDE.md` → Open decisions (Minimum macOS version); `docs/tech/stack.md` → Platform
  Targets.
- **Done when** — Changing one of the two values without the other fails CI.

### [x] P0.5 `[DevOps]` Module boundary enforcement
- **Work**
  - Add CI checks for the binding import rules: the engine logic never imports an adapter, only
    the engine command wiring imports adapters, the app never links the engine, and the Journal and
    the Ledger are separate.
- **Spec** — ADR-001, ADR-003; `CLAUDE.md` → Local choices (Modules).
- **Done when** — A test commit that breaks each rule fails CI with a message that names the rule.

### [x] P0.6 `[DevOps]` Dependency and supply-chain hygiene
- **Work**
  - Commit resolved package versions. Enable automated dependency-update pull requests for Swift
    packages and CI actions.
  - Enable secret scanning on the remote repository.
  - Add a `.gitignore` audit so that no credentials, Journals, Ledgers, local TOML or scratch
    fixtures can be committed.
- **Done when** — Dependency-update PRs arrive. A test secret pushed on a branch is flagged.

### [x] P0.7 `[DevOps]` Developer workstation prerequisites
- **Work** — Write a `CONTRIBUTING.md` section listing, and a check script verifying:
  - Apple Silicon Mac, Xcode toolchain, SwiftLint.
  - Orca ADE installed (the version recorded in the feasibility probes, or later).
  - At least one agent CLI installed and authenticated (`claude`, `codex`).
  - Access to the scratch Linear team (see P15.1) and the Developer ID signing identity (see
    P16.1), where the developer's role needs them.
  - `git` available on the path used by a bare environment.
- **Spec** — `docs/tech/stack.md` → Distribution (four prerequisites); feasibility probes → Method.
- **Done when** — A new developer runs the check script and gets a pass/fail per prerequisite.

### [x] P0.8 Glossary-term conformance tooling
- **Work**
  - A lightweight lint (CI job, warning level) that flags known forbidden synonyms in identifiers,
    UI copy and commit messages. Examples: lowercase `project` for our Project in type names,
    "attempt" used where the code means Round, a Port name in a test name.
- **Spec** — `docs/glossary.md`; `CLAUDE.md` → Ubiquitous language.
- **Done when** — The job runs in CI and reports findings on a pull request.

---

## Phase 1 — Decision gates

These decisions were open in the spec or in `CLAUDE.md`. **All are closed** by the spec's
*Decision Gates Ruling — 2026-09-15* (`risks.md#decision-gates-ruling-2026-09-15`); the rule is
cited by gate number there. This roadmap still does not restate the decisions — read them in the
spec. Two carry a probe that must pass before the code that depends on them: **G-6** (settle
workflow-state group) and **G-8** (threaded-reply parent comment on the Delta Read).

| Gate | Decision (now closed) | Where recorded | Blocks |
|---|---|---|---|
| G-1 | Whether local git reads sit behind a Port | ADR-001; system-overview → Open Questions | P6.1–P6.6 |
| G-2 | Minimum macOS version (the higher of Orca ADE's floor and the SwiftUI APIs used) | stack.md → Platform Targets; `CLAUDE.md` | P16.2 (final value); P14 (API choice) |
| G-3 | On-disk paths for the Ledger and the Routing Table TOML (Journal path is given in OQ52; config root in OQ13) | `CLAUDE.md` → Open decisions; risks.md OQ13, OQ52 | P2.1, P3.1, P3.5 |
| G-4 | SQLite DDL and migration policy for the Journal and the Ledger | `CLAUDE.md` → Open decisions | P3.1, P3.5 |
| G-5 | Window app versus menu-bar app | `CLAUDE.md` → Open decisions | P14.1 |
| G-6 | Which Nav Flow screens the app owns versus Linear | `CLAUDE.md`; ooux/nav-flow.md | P14.4–P14.8 |
| G-7 | Build Act firing cadence, and what stops build firing after land | shift-scheduling/overview → Open Questions | P13.2 |
| G-8 | How a comment is classified as an answer or not (TD9, A19) | risks.md TD9 | P11.2 |
| G-9 | How "accepted without reopening the diff" is observed | morning-report/overview → Open Questions | P12.2 |
| G-10 | Whether "Night opened" notifies on a normal Night | morning-report/notify-the-operator-of-exceptions → Open Questions | P12.5 |
| G-11 | How a clause whose citation no longer resolves is reported at verification (unmet or a third outcome) | verification/overview → Open Questions | P10.5 |
| G-12 | Glossary entries for *Engine*, *Yellowhammer app*, *rehearsal Night* | system-overview → Open Questions | Naming in P4, P14, P15 |
| G-13 | Whether `review_rounds_max = 2` stays now that check rounds share it (R6) | bounds/overview → Open Questions | Default in P2.2 (value only) |
| G-14 | Software update channel for the directly distributed `.app` (not addressed in the spec) | — (raise as a spec gap) | P16.5 |
| G-15 | Lease TTL / heartbeat revision after probe results (A2) | loop-state/overview → Open Questions | P3.4, P8.10 (values only) |
| G-16 | Identifiers for the re-selection, refusal-drift promotion and divergence promotion bounds | bounds/overview | P2.2, P11.6 |
| G-17 | Board representation of a per-Card Override (glossary → Override; OQ13 mentions an Override label) | glossary.md; risks.md OQ13 | P7.6 |

### [x] P1.1 Raise spec conflicts found while building this roadmap
- **Work** — Propose these corrections to the spec owners. **Do not edit the spec from this repo.**
  1. `shift-scheduling/fire-an-act-on-schedule` still says cross-Project contention is settled by
     "machine-wide Bounds, arbitrated by compare-and-reserve against the Ledger". OQ15 and ADR-003
     leave no machine-wide Bounds, and the Ledger holds Probe Results only.
  2. `shift-scheduling/open-and-close-the-night-card` still has a criterion about a machine-wide
     Bound being reached.
  3. `loop-state/record-failure-cause-recurrence` says the Ledger holds "the two machine-wide
     Bounds' running totals".
  4. `docs/tech/system-overview.md`: the Integration Map diagram has "admits a lane by
     compare-and-reserve". *Environment Differences* keeps a machine-wide-bound exhaustion passage
     (flagged there as unreconciled). It also says an Attempt is held by an agent CLI process "in
     an Orca terminal", which OQ57 retired.
  5. `docs/tech/stack.md` → Notable Constraints still says Orca ADE "owns worktrees and terminals".
  6. `landing/open-one-pull-request-per-repository` asks for each Card's "cost" in the pull request
     body. Cost accounting is retired (OQ16).
  7. `bounds/escalate-a-question-to-the-operator` still lists the acknowledgement strings as
     "Open". OQ37 closed them (see `board-projection/read-board-changes-by-delta`).
  8. The Delta Read query: the story uses a `comments` root with an issue→project filter. The
     feasibility probe resolution table names `projectComments`.
  9. `routing/overview` → Known Constraints attributes the no-repeat rule to DR5 (via OQ13). DR5
     is the Check ruling.
  10. Assumption ID **A20** is used twice in risks.md (flagged in the feasibility probes).
- **Also raise against this repo's `CLAUDE.md`:** it still says Acts are fired by an Orca ADE
  Automation and that Orca ADE owns all scheduling. OQ53 moved scheduling to `launchd`/cron. The
  "How an Orca Automation invokes an executable" open decision is closed by OQ53.
- **Done when** — Each item is filed with the spec owners and answered (accepted or rejected).
- **Outcome (2026-09-15)** — All ten items and the `CLAUDE.md` item were accepted and fixed in the
  spec and in `CLAUDE.md`. Item 9 was already fixed at spec HEAD. The same pass also fixed: the
  Open Questions register lost in the `risks.md` compression (every `OQn` citation resolves again),
  ADR-002's "three Orca automations configured by hand", ADR-001's retired Orca Automation link,
  stale open items already closed by OQ8/OQ10/OQ19, and Linear's request budget (the app identity's
  is 5,000/hour; 2,500 was a personal API key's).

---

## Phase 2 — Configuration

### [x] P2.1 Machine-wide configuration file
- **Work**
  - Read the machine-wide TOML base file: Linear workspace authorization reference, base Routing
    Table entries, CLI Adapter declarations, machine default GitHub credentials.
  - Parse the routing entry shape: optional `kind` (longest-prefix match, default `*`), optional
    `repo_role` (default `*`), primary route (table or `cli/model/effort` shorthand), ordered
    `fallbacks` (with the `cli/model` pair defaulting rules).
  - Report parse errors with file, line and key.
- **Spec** — risks.md OQ13 Facet 1; `routing/overview`; system-overview → CLI Adapters and the
  Routing Table.
- **Gate** — G-3.
- **Agent** — Opus 5 Medium.
- **Done when** — Valid fixture files load into typed configuration. Each malformed fixture gives a
  precise error.

### [x] P2.2 Per-Project configuration files
- **Work**
  - Read one TOML file per Project: `id`, `name`, `linear_project`, `[[repos]]` (`name`, `path`,
    `role`, required `check`, `protected_paths`), the single specification source (`spec_source`
    path, or a working repo with `role = "spec"`), `[limits]` (`review_rounds_max` default 2,
    `attempts_per_card` default 3, `unanswered_nights_max` default 3, the three promotion and
    re-selection thresholds), optional per-Project routing overrides, and an optional per-Project
    GitHub credential.
  - Keep the Repo Role vocabulary open, with the four standard roles recognised.
- **Spec** — risks.md OQ13 Facet 1, OQ14, OQ45 (per-Project GitHub credential), OQ51 (Spec Source);
  `bounds/overview`; `graph-execution/gate-a-card-on-the-repository-check`.
- **Gates** — G-13 (default value only), G-16 (key names for the three unnamed bounds).
- **Agent** — Opus 5 Medium.
- **Done when** — Fixture Projects load with defaults applied where keys are absent and allowed.

### [x] P2.3 Load-time validation with per-Project failure isolation
- **Work** — Validation rules, each with a precise error:
  1. **Working repo exclusivity:** the same path declared as a working repo in two Projects
     invalidates **both** Projects. Sibling Projects still load.
  2. **Exactly one specification source** across both kinds. Zero or more than one invalidates
     that Project only.
  3. **Explicit `check`** on every working repo. A missing key is refused; it is never read as
     `none`.
  4. **`unanswered_nights_max` is an integer ≥ 1.** Zero or negative is refused.
  5. **Adapter validation:** every route resolves to a declared CLI Adapter. A CLI in the Routing
     Table with no adapter is refused with an explicit error.
  6. **Declaration kind** is checked, not just the path: a Spec Source in Project A and a working
     Repo in Project B is valid.
  7. A Spec Source carries a path only (no role, check or protected paths).
- **Spec** — risks.md OQ13, OQ14, OQ51; `routing/add-an-agent-cli`;
  `feature-authoring/overview` → Business Rules; `graph-execution/gate-a-card-on-the-repository-check`.
- **Agent** — Fable 5.1 Medium.
- **Done when** — A fixture matrix covers every rule, including "two conflicting Projects refused,
  third Project loads".

### [x] P2.4 Routing Table merge
- **Work**
  - Merge the machine-wide base table with each Project's optional override table **once, at load**,
    keyed by (Kind, Repo Role). A per-Project entry replaces its base counterpart outright,
    fallbacks included.
  - Expose the merged result as one flat table per Project.
- **Spec** — `routing/overview`; `routing/resolve-a-route-for-a-card`; Machine Scope Ruling
  (risks.md).
- **Agent** — Fable 5.1 Medium.
- **Done when** — Fixtures prove that an override replaces the base entry and its fallbacks, and
  that non-overridden entries pass through.

### [x] P2.5 Missing-configuration behaviour
- **Work**
  - When an Act fires and configuration is missing or uninitialized, `yh` exits with code 1 and
    prints remediation text pointing to `yh setup` or `Yellowhammer.app`.
  - When `--project <id>` names a Project that is absent or invalidated, `yh` exits with code 1
    without running an Act.
- **Spec** — risks.md OQ13 Facet 2; OQ52 Face 1 (orphaned LaunchAgents fail fast).
- **Agent** — Opus 5 Medium.
- **Done when** — Both cases are covered by CLI tests that assert exit code and message.

---

## Phase 3 — Local stores

### [x] P3.1 Journal store: creation and schema
- **Work**
  - One Journal per Project, created on first use at the Project's Journal path. The engine
    invocation for that Project is its only writer.
  - A schema that holds everything the epics name: Nights (with `project_id`), Features, Cycles,
    Cards (with repository label, Kind, authored order, state, `waiting_reason`, Block Reason),
    Attempts (route, classification, result, how it was consumed), Rounds (lens, verdict, requested
    changes, judged commit), routes tried / excluded routes per budget epoch, Leases (`runId`,
    heartbeat, expiry), Worktree ids and paths as a per-(Feature, repo) set, failure-cause hashes
    and recurrence counts, last-posted Managed Block hashes, `clause` table (cid, issue, level,
    text, location ID, provenance, invalidation state and cause), Transcription Block provenance,
    Outbox entries, banked replies (Night, per-repo mainline commit), adoption-refusal and
    divergence counts, and the append-only `event` table.
  - Repo Lane membership is **not** stored. It is derived from each Card's repository label.
  - Schema versioning and a forward migration path.
- **Spec** — `loop-state/overview`; `shift-scheduling/do-one-acts-work-and-exit`;
  `feature-authoring/author-citable-definitions-of-done`; risks.md OQ52 (Journal path, never
  deleted by the product).
- **Gates** — G-3, G-4.
- **Agent** — Fable 5.1 Medium.
- **Done when** — A Journal is created for a fixture Project. Migrations run from an empty file to
  the current version. A second Project gets a separate file.

### [x] P3.2 Journal single-writer discipline
- **Work**
  - An invocation opens only its own Project's Journal. Nothing in the engine can take a sibling
    Project's Journal path.
  - Two overlapping Acts of the **same** Project do not corrupt state (single writer plus leases).
- **Spec** — `shift-scheduling/fire-an-act-on-schedule`; `loop-state/claim-and-heartbeat-a-run-lease`;
  ADR-002.
- **Agent** — Fable 5.1 High.
- **Done when** — Tests run two overlapping same-Project invocations and show no corruption. The
  engine has no API that addresses a second Project's Journal.

### [x] P3.3 Event log
- **Work**
  - Append-only event writing for every Act, including Act start/end, the reason an Act could not
    complete (where it can record one), `MainlineFetchFailed`, `AbsentNightDetected`,
    `AuthoringNoWorkAvailable`, `ManagedBlockDelimiterBroken`, notification delivery failures,
    rate-limit degradations (named as workspace-wide), crash reclaims.
  - No event log spans Projects.
- **Spec** — `shift-scheduling/do-one-acts-work-and-exit`; risks.md OQ12, OQ13; system-overview →
  Integration Map.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Each named event type is appended by at least one code path under test. The table
  refuses updates and deletes.

### [x] P3.4 Leases
- **Work**
  - Claim a lease on a Card for a run (`runId`) before dispatch.
  - Heartbeat every 60 seconds while work is in progress. Expire after a 10-minute TTL with no
    heartbeat. Keep both values configurable as "merely true today".
  - An unexpired lease blocks dispatch by another run of the same Project.
  - Lease revalidation is exposed so that every board write can check it (used by P5.4).
- **Spec** — `loop-state/claim-and-heartbeat-a-run-lease`; system-overview → Sleep hazard.
- **Gate** — G-15 (values).
- **Agent** — Fable 5.1 High.
- **Done when** — Rehearsal-assertable tests show claim, heartbeat, expiry, and refusal of a second
  claim while unexpired.

### [x] P3.5 Ledger store
- **Work**
  - One Ledger per machine, outside every Project, written by any Project's invocation under its own
    transaction.
  - It holds **only** Probe Result history per agent CLI. It has no Bounds, lane leases, Project
    roster, schedule or mode column.
- **Spec** — ADR-003; `routing/add-an-agent-cli`; risks.md OQ47, OQ48.
- **Gates** — G-3, G-4.
- **Agent** — Opus 5 Medium.
- **Done when** — Two concurrent invocations for different Projects write Probe Results without
  conflict. The schema has no table beyond Probe Result history.

---

## Phase 4 — Engine invocation shell

### [x] P4.1 Command surface for the Acts
- **Work**
  - `yh author --project <id>`, `yh build --project <id>`, `yh land --project <id>` as the Act
    contract (typed into scheduled jobs by hand, so it is stable).
  - A way for the Operator to force an Act, and to force the author Act for a named Feature.
  - A runtime switch for rehearsal mode on a Night (a runtime mode, never a build configuration or
    scheme).
- **Spec** — `shift-scheduling/fire-an-act-on-schedule`; `feature-authoring/select-the-next-feature`
  (forced authoring); risks.md OQ52 Face 2 (gestures); `CLAUDE.md` → Names.
- **Gate** — G-12 (term naming).
- **Agent** — Opus 5 Medium.
- **Done when** — Each subcommand parses, loads configuration for exactly one Project, and exits.

### [x] P4.2 One Act's work, then exit
- **Work**
  - An invocation does exactly one Act's work and exits. It keeps no state in memory between Acts,
    holds no timer, and starts no background process that outlives it.
  - A resumed Act rebuilds Attempt and Round counts, routes tried and Worktree paths from the
    Journal alone.
- **Spec** — `shift-scheduling/do-one-acts-work-and-exit`; `CLAUDE.md` → What the app must not do
  (Nothing resident).
- **Agent** — Fable 5.1 Medium.
- **Done when** — Tests kill an invocation mid-Act and show that the next invocation reconstructs
  state from the Journal only.

### [x] P4.3 Act trigger predicates
- **Work**
  - The author Act does work when the Project has no ready Cards, or when forced.
  - The build Act does work repeatedly through the Night.
  - The land Act does work when the in-flight Feature's Cycle has no unfinished Cards. Cancelled
    Cards do not count as unfinished.
  - When a predicate is false, the Act records an idle tick and exits 0.
- **Spec** — `shift-scheduling/fire-an-act-on-schedule`; risks.md OQ13 Facet 2.
- **Agent** — Opus 5 Medium.
- **Done when** — Journal fixtures cover each predicate in both directions.

### [x] P4.4 Night lifecycle in the Journal
- **Work**
  - Record the Night (per Project, `project_id` first-class) at the first Act of the Night.
  - Record Night close with a status and a reason.
  - Detect a Night left open with no completion, and record it on that Project's next Night.
- **Spec** — `shift-scheduling/open-and-close-the-night-card`; risks.md OQ52 Face 2 (Night carries
  `project_id`).
- **Agent** — Fable 5.1 Medium.
- **Done when** — Journal tests cover open, close, and "opened and died" detection.

### [x] P4.5 Resumption self-audit (absent Nights)
- **Work**
  - At the first Act of a run, compare the Journal's Night and event timestamps against the
    Project's configured schedule. Log `AbsentNightDetected` with the missed intervals.
  - Hand the gap to the Night Summary (P12.1).
  - Never charge `unanswered_nights_max` for missed Nights, and never auto-Block for them.
- **Spec** — risks.md OQ12 Surface 2, OQ47; `bounds/bound-unanswered-nights`.
- **Depends on** — the schedule representation from P13.2.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Fixtures with missed intervals produce the event and no bound change.

---

## Phase 5 — Board: Linear

### [x] P5.1 `[DevOps]` Linear board identity registration
- **Work**
  - Register Yellowhammer's own Linear OAuth 2.0 application (client credentials, `actor=app`),
    one for the scratch workspace and one for production.
  - Store client credentials in the macOS Keychain on developer and CI machines. Keep them out of
    the repo. The configuration file holds a keychain token reference only.
  - Document rotation and revocation.
- **Spec** — system-overview → *Why the board identity is its own subsystem concern*; feasibility
  probes → Linear (Identity & notifications); risks.md OQ13 (keychain token reference), OQ49.
- **Agent** — Sonnet 5 Medium.
- **Done when** — A token for the app identity can be obtained from each workspace, and a comment
  it writes triggers the Operator's inbox notification.

### [x] P5.2 Board adapter: authenticated GraphQL access
- **Work**
  - Authenticate as the registered identity, never as a personal API key.
  - Scope every read and write to one Project's Linear project.
  - Record request and complexity budget signals from responses, and handle rate-limit refusals.
  - Keep vendor types, error shapes and query language inside the adapter. Only Yellowhammer
    vocabulary and opaque identifiers cross the Port.
- **Spec** — ADR-001; stack.md → Board access; feasibility probes → Linear.
- **Agent** — Opus 5 Medium.
- **Done when** — Adapter tests against the scratch workspace read a Linear project's issues.
  Nothing outside the adapter refers to a Linear type.

### [x] P5.3 Linear provisioning (setup-time)
- **Work**
  - Provision the team's `Waiting on You` workflow state if missing (once per team, shared by
    Projects in that team).
  - Provision the mutually exclusive object-type label group (`Feature`, `Card`, `Night Card`).
    Detect a clash with existing workspace labels of the same name (the probe found `Feature`
    already present).
  - Provision the Block Reason label group and disposition labels the stories need.
  - Verify or create each Project's Linear project.
  - Make provisioning idempotent and report exactly what it changed.
- **Spec** — risks.md OQ2, OQ13 Facet 1; board-projection/overview; feasibility probes → Linear
  (A16, A17).
- **Agent** — Opus 5 Medium.
- **Done when** — Running provisioning twice against the scratch team changes nothing the second
  time. A label-name collision is reported and not overwritten.

### [x] P5.4 Outbox
- **Work**
  - Every board write goes through the Outbox: issue creation, Managed Block rewrites, comments,
    labels, workflow state, assignment, attachments, `parentId` changes, `issueArchive`, Night Card
    creation and completion.
  - Entries are held in the Project's Journal and survive process death. After a crash, each
    accepted entry is either completed or safely re-attempted.
  - Deterministic client UUIDs for `issueCreate` and `commentCreate`. A "conflict on insert"
    response is recorded as already applied.
  - Updates follow the JIT pre-flight read-modify-write rule. Description updates read
    `id description updatedAt` immediately before the mutation, never from a cached copy.
  - Delimiter fencing: replace only the text between `<!-- yh:managed:start -->` and
    `<!-- yh:managed:end -->`, leaving everything outside byte-identical. On missing or broken
    delimiters: do not write the description, record `ManagedBlockDelimiterBroken`, post a
    diagnostic comment, leave the description untouched.
  - Record each description write with the SHA-256 of the preserved human prose.
  - **Lease revalidation immediately before each write.** An expired or reclaimed lease aborts the
    write before it reaches Linear.
  - A permanent write failure is recorded in the event log for the Night Summary. A rate-limit
    refusal is recorded as a **workspace-wide** budget event.
  - Authoring-transaction support: a group of writes (Feature, Cycle, Cards, adoptions) that leaves
    either all of them or none of them on the board.
- **Spec** — `board-projection/write-board-updates-through-the-outbox`;
  `board-projection/maintain-the-managed-block`; risks.md OQ56.
- **Agent** — Fable 5.1 High.
- **Done when** — Rehearsal-assertable tests: replay after a killed run creates no duplicate issue
  or comment; a stale-lease write never reaches Linear; broken delimiters abort safely; a forced
  mid-transaction failure leaves no partial board.

### [x] P5.5 Delta Read
- **Work**
  - One batched compound query per Act, per Project: issues updated since the last sync plus
    comments created since the last sync, both scoped to the Project's Linear project.
  - Persist the last sync point in the Journal.
  - Filter out Yellowhammer's own comments by identity.
  - Surface Operator edits to brief, DoD, links, labels, assignment and state (including
    `Cancelled`) before dispatch decisions.
  - Detect human changes that break the authoring invariant (a Card moved to another repository)
    and report them instead of dispatching.
  - Reconcile deleted or manually re-stated Cards against the Journal.
  - When the budget is exhausted, do less work rather than act on stale reads, and record a
    workspace-wide degradation event.
- **Spec** — `board-projection/read-board-changes-by-delta`; risks.md OQ55.
- **Agent** — Fable 5.1 High.
- **Done when** — Scratch-team tests show a human comment and a state change picked up by one
  request. A sibling Project's Card in the same team is never selected.

### [x] P5.6 Managed Block rendering and hash-skip (Cards)
- **Work**
  - Render the Card Managed Block: Kind, repository, Architectural Brief (with Transcription
    Blocks), Definition of Done with clause markers and Spec Citations, position in its Repo Lane's
    authored order, managed footer. No predecessor links.
  - After each Attempt, render route, Check result (including "green came from a model alone" for
    `check = none`), Rounds with lens and verdict, outcome, and how the Attempt was consumed.
  - Keep disposition labels in step, including a Block Reason that tells blocked-by-check from
    blocked-by-reviewer. No label carries the Project.
  - Hash the **rendered** block and skip the write when the hash equals the last-posted hash.
  - Stop maintaining a Cancelled Card's block from the Act boundary where cancellation is read.
- **Spec** — `board-projection/maintain-the-managed-block` (first story).
- **Agent** — Fable 5.1 Medium.
- **Done when** — Rehearsal tests show hash-skip, label-group exclusivity, and no writes to a
  Cancelled Card.

### [x] P5.7 Night Card open and close
- **Work**
  - The first Act of a Project's Night creates that Project's Night Card through the Outbox,
    **before** any work is dispatched. It is an ordinary issue with the Night Card label, in the
    Project's Linear project.
  - Exactly one Night Card per Project per Night, including idle Nights. A resumed Act never creates
    a second one.
  - Completion at the end of the Night carries the Night Summary (content from P12.1). Until P12
    lands, completion carries a placeholder verdict.
  - Record the idle verdict for `AuthoringNoWorkAvailable`.
- **Spec** — `shift-scheduling/open-and-close-the-night-card`; DR7; risks.md OQ13 Facet 2.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Rehearsal Night against the scratch team: one Night Card opens and closes; a
  killed-and-resumed Act leaves exactly one.

### [x] P5.8 Board state writes for Cards and Features
- **Work**
  - Workflow-state transitions Yellowhammer owns: Ready, in progress, Blocked (with Block Reason),
    Waiting on You (with assignment to the Operator as delivery), Done.
  - Read `Cancelled` and never write it. Treat it as taking effect at the next Act boundary, never
    as deletion.
  - Report a Waiting on You Card with no Journal record behind it as an anomaly on the Night Card,
    and never dispatch it.
  - Repost Card board state from the Journal after a crash.
- **Spec** — board-projection/overview; `bounds/escalate-a-question-to-the-operator`; glossary →
  Cancelled.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Rehearsal tests cover each transition and the anomaly case.

---

## Phase 6 — Repositories & Worktrees

> **Gate G-1** (git behind a Port or not) must be closed before this phase starts.

### [x] P6.1 Mainline refresh at Act start
- **Work**
  - At the start of each author, build and land Act, refresh each working repo's remote-tracking
    mainline with a non-destructive fetch of its default branch.
  - On failure (offline or unreachable), continue on the cached ref and record
    `MainlineFetchFailed`.
  - Never fetch a Spec Source. Read its local default branch or `HEAD`.
- **Spec** — system-overview → Integration Map (Engine → Configured repositories); risks.md OQ19.
- **Agent** — Opus 5 Medium, or Gemini Flash 3.8 Medium.
- **Done when** — Fixture repos cover fetch success, fetch failure with fallback, and a Spec Source
  that is never fetched.

### [x] P6.2 Ancestry test
- **Work** — Given a Feature Branch and a repository, decide whether the branch is an ancestor of
  that repository's mainline. Report the `k of N` merged fraction across a Feature's repositories.
- **Spec** — `feature-authoring/select-the-next-feature` (predecessor-ancestry story);
  `landing/announce-a-partial-landing`.
- **Agent** — Opus 5 Medium, or Gemini Flash 3.8 Medium.
- **Done when** — Fixture repositories with and without the branch merged give the right verdict,
  with no network access.

### [x] P6.3 Merge test (Mainline Conflict detection)
- **Work** — Test-merge a Feature Branch against mainline without touching any working tree,
  writing any commit or contacting GitHub. Return clean, or conflicting with the conflicting paths.
- **Spec** — `landing/open-one-pull-request-per-repository`; glossary → Mainline Conflict.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Fixture repos where mainline has and has not moved give the right verdict. The
  working tree and refs are unchanged afterwards.

### [x] P6.4 Path-scoped provenance diff
- **Work** — For a recorded (repo, paths, commit), resolve mainline head and report whether any
  recorded path changed between the commit and head. One `rev-parse` and one path-scoped diff per
  Card per foreign repository.
- **Spec** — `board-projection/check-card-readiness-at-dispatch`; risks.md OQ24.
- **Agent** — Opus 5 Medium, or Gemini Flash 3.8 Medium.
- **Done when** — Fixture repos cover touched, untouched and renamed-path cases, with no network.

### [x] P6.5 Mainline read for transcription and specification
- **Work**
  - Read file content at a mainline commit, for a working Repo or the Project's Spec Source, and
    return it with the commit it was read at.
  - Resolve Spec Citations (story ID `<epic>/<story>`, goal ID) against the Project's single
    specification source, as a resolves / does-not-resolve predicate.
  - Refuse any read of a repository outside the Project's configuration.
- **Spec** — `feature-authoring/author-an-architectural-brief`;
  `feature-authoring/author-citable-definitions-of-done`; risks.md OQ51.
- **Agent** — Opus 5 Medium, or Gemini Flash 3.8 Medium.
- **Done when** — Fixture spec repos resolve valid IDs, reject missing ones, and a path in another
  Project's repo is refused.

### [x] P6.6 Local commit, WIP and push operations
- **Work**
  - Commit uncommitted Worktree content as a WIP commit on the Feature Branch.
  - Reset a Worktree to the last known-good commit.
  - Push a Feature Branch (production only; rehearsal never pushes). Record push success, refusal
    by branch protection, and missing or insufficient credentials, each as a distinct outcome.
  - Choose the credential: the Project's GitHub credential when set, otherwise the machine default.
- **Spec** — `loop-state/reconcile-worktrees-at-act-start`; `landing/open-one-pull-request-per-repository`;
  system-overview → Engine → GitHub; risks.md OQ45.
- **Agent** — Opus 5 Medium.
- **Done when** — Fixture repos cover WIP commit idempotency, reset, and each push outcome (push
  itself is not asserted in rehearsal).

### [x] P6.7 Workspace adapter: Orca ADE worktrees
- **Work**
  - Request one Worktree per (Feature, repo) from Orca ADE, with the worktree name equal to the
    Feature Branch name `yh-<project>-<feature>` (no slashes).
  - Record ids and paths in the Journal as a per-Feature set keyed by repository. A Card resolves
    its Worktree by its repository label.
  - Release a Worktree only after its Feature Branch has been pushed and the ref recorded.
  - Run `git worktree prune` on the repository before each new allocation.
  - Never create, place or delete a worktree outside Orca ADE.
- **Spec** — `graph-execution/allocate-a-worktree-per-graph-and-repo`; feasibility probes → Orca ADE;
  risks.md OQ57.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Rehearsal-assertable: a three-repo fixture Feature holds three Worktrees whose
  names match their Feature Branches.

### [x] P6.8 Process fencing sweep
- **Work** — Find every process holding an open file or a working directory inside a Worktree path.
  Kill each one with `SIGKILL`. Wait until the count is zero before anything inspects, commits or
  resets the Worktree.
- **Spec** — `loop-state/reconcile-worktrees-at-act-start`; `loop-state/reclaim-an-expired-lease`.
- **Agent** — Fable 5.1 Medium.
- **Done when** — A test process left with its cwd in a fixture Worktree is terminated, and
  reconciliation waits for quiescence.

### [x] P6.9 Worktree reconciliation at build Act start
- **Work** — In order, for **every** path in this Project's in-flight Feature set, and only that set:
  1. Check the recorded path with `stat`. Never trust Orca ADE's list alone.
  2. Missing path: purge Orca's stale record (`orca worktree rm --force <id>`), note the lost build
     state in the Journal, return the Card to a clean slate.
  3. Run the process fencing sweep (P6.8).
  4. Uncommitted work: WIP commit on the Feature Branch, reset to last known-good commit, hand the
     WIP ref to the retry as context.
  5. A worktree this Act cannot account for is never treated as stale. It may be a sibling
     Project's.
  - Running reconciliation twice creates no duplicate WIP commit.
- **Spec** — `loop-state/reconcile-worktrees-at-act-start`; TD2.
- **Agent** — Fable 5.1 High.
- **Done when** — Rehearsal tests cover a ghost path, a dirty worktree, a sibling Project's
  worktree, and idempotency.

---

## Phase 7 — Dispatch & Routing

### [x] P7.1 Result schema and instruction contract
- **Work**
  - Define the forced JSON result schema(s) for architect, worker and reviewer outcomes, including
    the worker's "question for the Operator" outcome and the reviewer's verdict with requested
    changes.
  - Define how the instruction is composed from the Card, its Architectural Brief, its Definition
    of Done and its repository, plus the payloads that travel with it (WIP ref, answered question
    with every reply, banked replies with their Night and commits, round feedback).
  - Define fixture result files for rehearsal Nights.
- **Spec** — `graph-execution/run-a-card`; `bounds/escalate-a-question-to-the-operator`;
  `feature-authoring/author-the-cycle-and-card-dag` (adoption payload); routing/overview (the CLI
  owns execution).
- **Agent** — Fable 5.1 Medium.
- **Done when** — Schemas validate the fixture files. An empty or malformed file fails validation.

### [x] P7.2 Process lifecycle for agent CLI runs
- **Work**
  - Spawn the agent CLI directly inside the Worktree path, in its own process group.
  - On timeout or engine abort: `SIGTERM` to the group, a 3-second grace window, then `SIGKILL`.
  - Dual-key completion: exit status 0 **and** a non-empty, schema-valid result file. Exit 0 with a
    missing or invalid file is Crashed-Unknown.
  - Record an exit code attributable to the CLI, for route-failure classification.
  - Rehearsal mode never spawns a CLI. It reads fixture result files.
- **Spec** — `graph-execution/run-a-card`; `routing/add-an-agent-cli`; risks.md OQ57;
  system-overview → Integration Map (CLI Adapters → Agent CLIs).
- **Agent** — Fable 5.1 Medium.
- **Done when** — Tests with a stub executable cover clean exit, exit 0 with empty file, `SIGTERM`
  and `SIGKILL` with orphaned children, and rehearsal fixtures. Crash/kill behaviour of a real CLI
  is exercised by the Probe (P7.4), not asserted in rehearsal.

### [x] P7.3 CLI Adapters: `claude` and `codex`
- **Work** — One adapter per CLI, each defining:
  - argv shape for unattended dispatch with no prompt (closed stdin, permission mode or sandbox
    flags as each CLI requires);
  - forcing the result schema and locating the result file;
  - session resumption (for Rounds on the same worker);
  - mapping model and effort from the route;
  - parsing and validating structured output.
- **Spec** — `routing/add-an-agent-cli`; feasibility probes → Agent CLIs.
- **Agent** — Opus 5 Medium.
- **Done when** — Each adapter passes its Probe (P7.4) on a developer machine.

### [x] P7.4 Probes and Probe Results
- **Work** — A Probe per adapter that checks, and records in the Ledger:
  1. unattended dispatch with no interactive auth or permission prompt;
  2. schema-conforming result file on clean exit;
  3. process-group containment under `SIGTERM` and `SIGKILL`, with no leaked orphans;
  4. session resumption;
  5. drift in argv, session handling or output format when re-run after a CLI update.
  - A CLI that fails the unattended or containment probe is not offered as a route target, and the
    reason is reported. No cost probe exists.
- **Spec** — `routing/add-an-agent-cli`; ADR-003; risks.md OQ48.
- **Agent** — Opus 5 Medium.
- **Done when** — Probes run on the developer machine for `claude` and `codex` and write Ledger rows.
  A deliberately broken adapter stub is excluded from routing with a reason.

### [x] P7.5 `[DevOps]` Scheduled probe drift check
- **Work**
  - A CI job (on a self-hosted Apple Silicon runner with the CLIs installed and authenticated, or a
    documented manual release-checklist step if no such runner exists) that re-runs every Probe
    against the pinned and the latest CLI versions and fails loudly on drift.
- **Spec** — R11; `routing/add-an-agent-cli` (re-running the probe detects drift).
- **Agent** — Sonnet 5 Medium, or Gemini Flash 3.8 Medium.
- **Done when** — Drift in a CLI's output format turns the job red before a release ships.

### [x] P7.6 Route resolution
- **Work**
  - Resolve per Card at dispatch: select by per-Card Override, then Kind (longest prefix), then
    Repo Role; then filter by attempt-history exclusion and probe failure.
  - An Override beats Kind, Repo Role and attempt-history exclusion, but not probe failure.
  - Fall through configured fallbacks before giving up.
  - Zero candidates: Blocked with Block Reason `hard failure` (`fallbacks exhausted`), no phantom
    Attempts, lane moves on.
  - Record the resolved route on the Attempt and report it onto the Card.
  - Read the merged table fresh on each Act. Nothing is learned or inferred.
- **Spec** — `routing/resolve-a-route-for-a-card`; risks.md OQ13 Facet 3.
- **Gate** — G-17.
- **Agent** — Fable 5.1 High.
- **Done when** — Rehearsal-assertable tests cover each precedence rule, fallback walk, probe
  exclusion and the zero-candidate block.

### [x] P7.7 Route exclusion on retry
- **Work**
  - After a capability failure, exclude every route already tried for the Card in its budget epoch.
    The set is held in the Journal.
  - Crashed-Unknown: consume the Attempt, do not exclude, retry the same route once.
  - An attributable CLI exit code: treat as a route failure and exclude.
  - Resuming from Waiting on You: consume an Attempt, do not exclude.
  - An Override pinned in triage resets the budget epoch and exclusion set.
  - Record whether each retry landed on a genuinely different route (for P12.2).
- **Spec** — `routing/exclude-tried-routes-on-retry`; risks.md OQ13 Facet 3.
- **Agent** — Fable 5.1 High.
- **Done when** — Rehearsal-assertable tests cover each classification.

---

## Phase 8 — Build Act

### [x] P8.1 Build Act sequence
- **Work** — In order, each build Act:
  1. Opens or joins the Night (P5.7).
  2. Refreshes mainlines (P6.1).
  3. Reclaims expired leases (P8.10), then reconciles Worktrees (P6.9), then reposts board state
     from the Journal (P5.8).
  4. Performs the Delta Read (P5.5) and applies Cancelled, edits and answers.
  5. Derives Repo Lanes from the in-flight Feature's Cards.
  6. Runs lanes concurrently, and each lane's Cards one at a time in authored order.
  7. Writes back and exits.
- **Spec** — `graph-execution/overview`; `shift-scheduling/fire-an-act-on-schedule`.
- **Agent** — Fable 5.1 Medium.
- **Done when** — A rehearsal build Act over a fixture Feature performs the steps in order, as
  recorded in the event log.

### [x] P8.2 Readiness Check at dispatch
- **Work** — On every build Act, for each Card about to dispatch:
  - An Architectural Brief and a Definition of Done are present.
  - Every Spec Citation still resolves.
  - For each Transcription Block, run the path-scoped provenance diff (P6.4). Stale means
    Divergence: Waiting on You with `waiting_reason = divergence`, naming what moved. Increment the
    consecutive-divergence count, reset it on any clean pass.
  - An Operator edit inside a Transcription Block voids that block's stamp (Operator-supplied, as of
    the Night seen), with no refusal, no Attempt and no notice. An edit elsewhere voids nothing.
  - Detect and mint IDs for untagged human clauses (Author-supplied), stamp the marker through the
    Outbox, and validate the citation. Clause text or citation edits invalidate earlier
    verification results with the named cause.
  - A failing Card is not dispatched, consumes no Attempt or Round, the failure is reported on the
    Card, and the lane moves on.
  - No Feature-level pass.
- **Spec** — `board-projection/check-card-readiness-at-dispatch`;
  `feature-authoring/author-citable-definitions-of-done` (second story);
  `feature-authoring/author-an-architectural-brief`.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Rehearsal tests cover each failure kind, the Divergence route, the voided stamp,
  and untagged clause minting.

### [x] P8.3 Protected Paths refusal
- **Work**
  - Before dispatch, check the Card's declared scope against the repository's protected paths.
  - A match is not dispatched, moves to Blocked or Waiting on You carrying the protected path, and
    consumes no Attempt. The lane moves on.
  - Every user-facing description states that this is a scoping check and not a sandbox.
- **Spec** — `bounds/refuse-protected-paths-before-dispatch`; R3.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Rehearsal tests show refusal with no dispatch. The limitation text appears in
  user-facing copy.

### [x] P8.4 Card run: architect → worker → Check → reviewer
- **Work**
  - Claim the lease (P3.4) and heartbeat throughout.
  - Resolve the route (P7.6). Compose the instruction (P7.1). Dispatch architect, then worker, in
    the lane's Worktree (P7.2).
  - Run the repository Check (P8.5) after the worker and before the reviewer.
  - Dispatch the reviewer. On approval after a passing Check, the Card ends successfully.
  - Record the outcome in the Journal and project it (P5.6).
- **Spec** — `graph-execution/run-a-card` (first story); `graph-execution/overview` (roles are
  internals of a run, not actors).
- **Agent** — Fable 5.1 High.
- **Done when** — A rehearsal run over fixture result files takes a Card from Ready to done, with
  every step recorded. Model output and the Check result are not asserted.

### [x] P8.5 Engine-run Check
- **Work**
  - Run the repository's declared `check` command in the Worktree, and record its output.
  - `check = none`: record that the green came from a model alone.
  - A failed Check creates a Round with `lens = check`, returning to the same worker, route and
    Worktree, bounded by `review_rounds_max`.
  - Attach Check output to the Card.
  - The accepted cost of a flaky Check (R6) is stated wherever this is documented.
- **Spec** — `graph-execution/gate-a-card-on-the-repository-check`; DR5.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Wiring tests show the Check runs between worker and reviewer and a failure opens a
  `check` Round. The Check result itself is not asserted in rehearsal.

### [x] P8.6 Rounds (review and check lenses)
- **Work**
  - Reviewer requests changes: Round `n+1` with `lens = review` on the same worker, route and
    Worktree. No Attempt consumed.
  - Each Round records lens, verdict, requested changes and judged commit, and is shown on the Card.
  - On exhausting `review_rounds_max`, the Card is Blocked only if the Attempt budget is also
    exhausted. Block Reason distinguishes blocked by check from blocked by reviewer.
- **Spec** — `graph-execution/run-a-card` (second story); `bounds/bound-review-rounds-and-attempts`.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Rehearsal-assertable bound arithmetic with small configured values.

### [x] P8.7 Attempts and hard failure
- **Work**
  - A hard failure ends the Attempt. The retry is a fresh dispatch with route exclusion (P7.7).
  - Bound Attempts by `attempts_per_card`. A Card blocks only when both budgets are exhausted, or
    when no route remains.
  - Record how each Attempt was consumed, so the account can tell three failed routes from two
    reboots.
- **Spec** — `graph-execution/run-a-card` (third story); `bounds/bound-review-rounds-and-attempts`;
  system-overview → Interruption.
- **Agent** — Fable 5.1 High.
- **Done when** — Rehearsal-assertable tests cover both-budgets rule and consumption accounting.

### [x] P8.8 Failure-cause recurrence
- **Work**
  - Reduce each failure to a failure-cause hash stored against the Card in the Journal.
  - Count recurrences across that Project's Nights. On recurrence, promote to Triage instead of
    retrying, even with budget left. Never correlate across Projects.
  - Show the promotion and its reason on the Card.
- **Spec** — `loop-state/record-failure-cause-recurrence`.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Rehearsal tests over multiple Nights promote on recurrence, not on first occurrence.

### [x] P8.9 Block mid-lane and Cancelled Cards
- **Work**
  - A Blocked or Waiting on You Card does not halt its lane. Later Cards run with their own budgets.
  - Record the blocked Card as a hole for landing (P10.4).
  - Report a later Card that needed the blocked Card's work as an authoring invariant violation.
  - A Card cancelled in Linear drops out at the next Act boundary. The running agent is not
    interrupted. No Attempt consumed. Nothing posted to it. No Worktree released early. Commits
    stand. Journal row intact. Reopening restores it with no budget reset.
- **Spec** — `graph-execution/handle-a-block-mid-graph`; `graph-execution/run-a-card` (fourth story).
- **Agent** — Fable 5.1 Medium.
- **Done when** — Rehearsal tests: a lane continues past a block; cancel and reopen round-trips with
  counters unchanged.

### [x] P8.10 Lease reclaim
- **Work**
  - A later Act of the same Project reclaims an expired lease with a new `runId`.
  - Before reposting or retrying, run the process fencing sweep on the Worktree (P6.8).
  - Classify: a valid result file means the Attempt finished (record its outcome); no valid file
    means Crashed-Unknown with no route exclusion unless a CLI-attributable exit code exists.
  - Repost the Card to Ready with a crash comment through the Outbox.
  - Record the crash for the Night Summary.
- **Spec** — `loop-state/reclaim-an-expired-lease`.
- **Gate** — G-15 (values only).
- **Agent** — Fable 5.1 High.
- **Done when** — A rehearsal kills a real engine invocation mid-Card; the next build Act reclaims
  within the TTL, with the right classification.

### [x] P8.11 Rehearsal boundaries in the build Act
- **Work** — In rehearsal mode the build Act never dispatches an agent CLI (fixture result files),
  never pushes, and never opens a pull request. It still writes to Linear, allocates real Worktrees,
  uses the real Ledger, and never commits into a Worktree.
- **Spec** — system-overview → Environment Differences.
- **Agent** — Fable 5.1 Medium.
- **Done when** — A rehearsal build Act leaves no process spawn of any agent CLI and no push in its
  event log.

---

## Phase 9 — Author Act

### [x] P9.1 Author Act sequence and quiet Nights
- **Work** — In order:
  1. Open the Night Card (P5.7).
  2. If a Feature is already in flight for this Project (including returned, Blocked or
     half-triaged), author nothing and record the skip, naming the Feature.
  3. Run the predecessor-ancestry gate (P9.2).
  4. Select (P9.3) and author (P9.4–P9.7) in one transaction.
  5. If nothing is selectable, record `AuthoringNoWorkAvailable` and close as an idle Night.
- **Spec** — `feature-authoring/select-the-next-feature`; risks.md OQ13 Facet 2.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Rehearsal tests cover each quiet-Night reason, each recorded on the Night Card.

### [x] P9.2 Predecessor-ancestry gate
- **Work**
  - Check that the predecessor Feature's Feature Branches are ancestors of mainline in every
    repository it touched (this Project's repos only).
  - Otherwise: author nothing, and name the predecessor and the repositories not yet containing it.
    No Worktree, dispatch or Attempt.
  - A merged Partial Landing satisfies the gate for the repositories it reached. A verified but
    unmerged Feature does not.
  - On the same pass, re-run the merge test on every unmerged branch (P6.3) and record Mainline
    Conflicts for the Feature card and the standing Summary line.
  - On the same pass, when ancestry first reaches all N, run the post-merge closure (P10.8).
- **Spec** — `feature-authoring/select-the-next-feature` (third story); `landing/overview`.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Fixture repositories with and without the predecessor merged give the right
  result. Pure local git, no model, no network.

### [x] P9.3 Feature selection
- **Work**
  - Read the Project's single specification source and its repos' mainlines.
  - Select one Feature and record it with written reasoning, including the sequence (what came
    before, what follows, why the seam falls there).
  - Determine and record the repositories it touches, from the specification and Repo Roles.
  - Consider Blocked Cards left by closed Features for Adoption (P11.5). Never select or adopt a
    Cancelled Card.
  - Support forced authoring for a Feature the Operator names.
  - Refuse, as Waiting on You before any dispatch: a Feature whose split cannot fall on a
    backward-compatible seam (naming the seam), a Feature whose repositories cannot be determined,
    and a Feature that needs a contract from a repository outside this Project.
- **Spec** — `feature-authoring/select-the-next-feature` (first, second and fourth stories).
- **Agent** — Fable 5.1 Medium.
- **Done when** — Wiring tests show selection results are recorded and refusals produce Waiting on
  You with no dispatch. The quality of the selection itself is not asserted.

### [x] P9.4 Authoring transaction: Feature, Cycle and Cards
- **Work**
  - Create the Feature Issue (Feature label, feature-level DoD in the description, selection
    reasoning).
  - Create the Cycle in the Journal, bound to the Feature.
  - Create one Card per unit of work, one repository each, as native sub-issues of the Feature Issue
    (`parentId`), each with Kind and authored order within its repository.
  - Apply the authoring invariant: split across repositories into a sequence of Features, or author
    a single coarser Card within one repository. No Card-to-Card links.
  - Include adopted Cards (P11.5) in the same transaction.
  - All of it through the Outbox as one all-or-nothing group. On failure, record it on the Night
    Card.
  - Create no Linear milestones or Linear cycles.
- **Spec** — `feature-authoring/author-the-cycle-and-card-dag` (first story); risks.md OQ54.
- **Agent** — Fable 5.1 High.
- **Done when** — Rehearsal tests: a forced failure mid-transaction leaves no issues; a resumed
  author Act creates no duplicates; Cards appear nested under the Feature Issue.

### [ ] P9.5 Citable Definitions of Done
- **Work**
  - Author clauses at Card and Feature level, before any code exists, each with one Spec Citation
    (story ID or goal ID) that resolves at authoring time.
  - Write only citable clauses. Mint a `cid` per clause, and write the line with the
    `<!-- yh:clause:<id> -->` marker and the citation.
  - Persist each clause in the Journal `clause` table with provenance `machine-found`.
  - A Feature too thin to cite goes Waiting on You before any dispatch, naming the uncitable
    clauses, with no Attempt and a Night Summary. Its roll-up reads `needs you`.
- **Spec** — `feature-authoring/author-citable-definitions-of-done`; DR4; risks.md TD8, OQ18.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Rehearsal tests check the clause line format, the Journal rows, and the
  thin-spec refusal path. Clause content is not asserted.

### [ ] P9.6 Architectural Briefs and Transcription Blocks
- **Work**
  - Author a brief per Card inside the Managed Block, separate from the DoD.
  - For a Card that consumes a contract from another repository (or content from the Spec Source),
    add a Transcription Block with repo, every path read, symbol, mainline commit and a content hash.
  - A needed contract that cannot be read sends the Feature to Waiting on You, naming the repository.
  - The agent CLI never gets the Spec Source path.
- **Spec** — `feature-authoring/author-an-architectural-brief`.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Rehearsal tests check the block format and provenance fields. Brief content is not
  asserted.

### [ ] P9.7 Refusal lifecycle at Feature level
- **Work**
  - A refused Feature Issue sits in Waiting on You with its Refusal content.
  - When `unanswered_nights_max` expires, convert to Blocked with Block Reason `unanswered`; the
    roll-up follows to `blocked`.
  - Count consecutive refusals for the refusal-drift promotion bound (P11.6).
- **Spec** — `feature-authoring/author-citable-definitions-of-done` (second story); glossary →
  Refusal.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Rehearsal bound arithmetic with a small configured value.

---

## Phase 10 — Land Act & Verification

### [ ] P10.1 Land Act sequence
- **Work** — In order: open or join the Night; refresh mainlines; for each Repo Lane: merge test
  (P10.3), push (P10.2), open pull request (P10.4); release Worktrees only after push; run
  Verification (P10.5); return (P10.6) or archive (P10.7); write back. The land Act fires once per
  Cycle, and no lane reopens after it.
- **Spec** — `landing/overview`; risks.md OQ8.
- **Agent** — Fable 5.1 Medium.
- **Done when** — A rehearsal land Act runs each step up to the rehearsal boundaries.

### [ ] P10.2 Push Feature Branches
- **Work**
  - Push each repository's Feature Branch before its Worktree is released, and record the ref on the
    Card.
  - A repository with no completed work: no branch, no pull request, recorded rather than failed.
  - Branch-protection refusal and missing or insufficient credentials: recorded and reported on the
    Feature card, naming the repository.
  - Never push to main.
- **Spec** — `landing/open-one-pull-request-per-repository`.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Wiring tests on local bare remotes cover each outcome. GitHub push is not asserted
  in rehearsal.

### [ ] P10.3 Mainline Conflict at landing
- **Work** — Test-merge each Feature Branch before Worktree release. A conflict is recorded and
  reported, nothing is resolved, and the landing still proceeds. A clean verdict is never described
  as "safe to merge".
- **Spec** — `landing/open-one-pull-request-per-repository`.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Fixture repos produce a conflict verdict with paths. Landing continues.

### [ ] P10.4 Publication adapter: GitHub pull requests
- **Work**
  - Open exactly one pull request per repository from its Feature Branch. Write-only: never read
    pull request state.
  - Body: Feature, its Cards with route, checks and Rounds, the "merging releases the next Feature"
    statement, the Mainline Conflict verdict as of this Night with conflicting paths, and a link to
    the Feature card for live state.
  - Partial Landing body: the fixed opening lines, the as-of stamp, every incomplete Card by title
    with reason and state, every unmet clause quoted with its citation, the carried-forward list, the
    "all N closes it" statement, and the DR4 contingency note next to the rule in documentation.
  - Record pull request links on the Feature card and contributing Cards.
  - The body is written once and never updated, duplicated or reopened.
  - Rehearsal never opens a pull request.
- **Spec** — `landing/open-one-pull-request-per-repository`; `landing/announce-a-partial-landing`;
  risks.md OQ31, OQ26.
- **Gate** — P1.1 item 6 (cost in the body).
- **Agent** — Fable 5.1 Medium.
- **Done when** — Body rendering is tested against fixtures (copy only, not model content). A
  production-only smoke test on a sandbox GitHub repository opens one pull request.

### [ ] P10.5 Verification clause by clause
- **Work**
  - Dispatch Verification to an agent other than the one that wrote the code.
  - Report every clause: `cid`, text, Spec Citation, provenance, verdict, what was checked, and the
    interpretation verified under. No aggregate "passed".
  - Verify against the DoD authored before code existed.
  - Surface an unresolved citation as its own outcome, never as met.
  - Write the report to the Feature Managed Block and the pull request bodies. State the "auditable,
    not sound" limitation beside it.
  - A Partial Landing always fails verification.
- **Spec** — `verification/verify-a-feature-clause-by-clause`; DR4.
- **Gate** — G-11.
- **Agent** — Fable 5.1 High.
- **Done when** — Report rendering and different-agent routing are tested. Verdicts are not
  asserted.

### [ ] P10.6 Return a Feature with unmet clauses
- **Work** — Return and assign the Feature to the Operator, listing unmet clauses with citations and
  met clauses too. Pull requests stay open and linked. Not Done, not archived. That Project's author
  Act authors nothing while it is returned.
- **Spec** — `verification/return-a-feature-with-unmet-clauses`.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Rehearsal state-transition tests.

### [ ] P10.7 Archive the Cycle on a verified Feature
- **Work**
  - Archive only when every clause is met. Record which route closed the Feature.
  - Detach surviving Blocked Cards (`parentId: null`) with counters intact. Move the Feature Issue to
    Done or archive it.
  - Never merge or close a pull request. Archival does not release the next Feature.
- **Spec** — `verification/archive-the-cycle-on-a-verified-feature`; risks.md OQ54.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Rehearsal tests for the verification route.

### [ ] P10.8 Closure by merge (observed ancestry)
- **Work**
  - When ancestry reaches all N (observed in P9.2), close the Feature by merge: move the roll-up to a
    closed value, auto-Block every Card still Waiting on You with its counters, detach surviving
    Cards, archive the Cycle, mark the Night triaged and green Cards accepted, post the post-merge
    narrative comment, and count it in that Night Summary.
  - For `k < N`, change only the merged fraction. Write no receipt.
- **Spec** — `landing/announce-a-partial-landing`; `morning-report/triage-the-morning`; R17, R18.
- **Agent** — Fable 5.1 High.
- **Done when** — Fixture repositories with k = 0, k < N and k = N produce exactly the specified
  writes.

### [ ] P10.9 Settle gesture (release)
- **Work**
  - Provide the Operator's settle action per Project: keep in flight or release. On a Partial
    Landing, offer `release` only.
  - `release` abandons the unmerged pull requests on our side and salvages unfinished Cards exactly
    as the merge does.
- **Spec** — `morning-report/triage-the-morning`; ooux/nav-flow.md (path 2).
- **Gate** — G-6 (where the gesture lives: Linear or the app).
- **Agent** — Fable 5.1 Medium.
- **Done when** — Rehearsal tests of both settle outcomes.

---

## Phase 11 — Escalation, Adoption & remaining Bounds

### [ ] P11.1 Waiting on You from a worker's question
- **Work** — Move the Card to Waiting on You, assign the Operator, post the question as a comment,
  record the question in the Journal, set `waiting_reason = question`. No Round, no Attempt. Hold
  the Worktree. The lane continues.
- **Spec** — `bounds/escalate-a-question-to-the-operator` (first story).
- **Agent** — Fable 5.1 Medium.
- **Done when** — Rehearsal tests with a fixture "question" result file.

### [ ] P11.2 Answer detection and resumption
- **Work**
  - Pre-landing, from the Delta Read: a recognised answer moves the Card out of Waiting on You and
    queues it for the next build Act. Resumption consumes an Attempt, no exclusion, reuses a held
    Worktree, and carries the question plus every reply flagged Operator-supplied.
  - Post acknowledgement (a) for a recognised answer and (b) for an unrecognised comment, with the
    canonical copy and nights remaining.
  - On a `divergence` Card: record and acknowledge with (d). No resume, nothing carried forward.
- **Spec** — `bounds/escalate-a-question-to-the-operator` (second story);
  `board-projection/read-board-changes-by-delta` (OQ37 copy).
- **Gate** — G-8.
- **Agent** — Fable 5.1 High.
- **Done when** — Rehearsal tests against real comments in the scratch team, for each branch.

### [ ] P11.3 Banked replies after landing
- **Work**
  - A recognised answer on a Card whose Cycle has landed is banked: recorded, acknowledged with (c),
    Card stays in Waiting on You, clock stopped.
  - A second reply appends, is acknowledged on its own, and is stamped with its Night.
  - Stamp each banked reply with the mainline commit of every repo the Card touches.
  - Derive the banked-answer marker on the Feature member row at read time. No roll-up change.
- **Spec** — `board-projection/read-board-changes-by-delta`; `board-projection/maintain-the-managed-block`
  (second story); risks.md OQ8.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Rehearsal tests cover first and repeated banked replies.

### [ ] P11.4 `unanswered_nights_max`
- **Work**
  - Count that Project's Nights while a Card waits. Past the bound, auto-Block with `unanswered`
    (question) or `undecided` (divergence), keeping the assignment and full reporting.
  - The clock halts on an answer, is suspended while Cancelled, restarts from zero on an adoption
    refusal, and is never advanced by a timer, calendar count or catch-up sweep.
  - Before any Worktree release, push the Feature Branch and record the ref.
  - An auto-Blocked Card is not terminal and can be re-readied with counters preserved.
- **Spec** — `bounds/bound-unanswered-nights`; DR8; risks.md OQ14, OQ47.
- **Agent** — Opus 5 Medium.
- **Done when** — Rehearsal-assertable bound arithmetic with `unanswered_nights_max = 1`, including
  the stopped-Project case (no Acts, no change).

### [ ] P11.5 Adoption
- **Work**
  - A later Feature adopts a Blocked Card left by a closed Feature: keep counters, round history,
    Block Reason and question; no new budgets.
  - Re-validate against current mainline under the authoring invariant before adopting.
  - On success: re-point `parentId` to the new Feature Issue, place the Card in the new Cycle and its
    repository's lane, start it in a fresh Worktree, record why it started cold, and include the
    banked-reply payload with its stated nature.
  - On failure: do not adopt or re-author, record a durable Divergence, return the Card as a fresh
    Waiting on You naming what moved, author the Feature without it. The board carries one current
    notice; the Journal accumulates them.
  - Adoption is part of the authoring transaction.
- **Spec** — `feature-authoring/author-the-cycle-and-card-dag` (second story);
  `feature-authoring/select-the-next-feature`.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Rehearsal tests of adopt and refuse-to-adopt, with counters verified.

### [ ] P11.6 Promotion and re-selection bounds
- **Work**
  - Refusal-drift promotion: consecutive refusals past the operator-set bound make a standing item.
    Nothing else changes.
  - Divergence promotion: consecutive failed adoptions past the bound make a standing item. Reset
    on a clean adoption.
  - Re-selection bound: ends the author Act's backlog walk for the Night.
  - Report proximity to each in the Night Summary.
- **Spec** — `bounds/overview`; `feature-authoring/select-the-next-feature`; risks.md OQ14 (4).
- **Gate** — G-16.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Rehearsal bound arithmetic with small values.

---

## Phase 12 — Morning report

### [ ] P12.1 Night Summary
- **Work** — Computed from the Project's Journal event table and written on the Night Card, every
  Night, including idle ones:
  - A constant-time verdict line.
  - Quiet-Night reasons, including the unlanded predecessor with its repositories.
  - Per Card touched: route, Check result (including model-alone greens), Rounds with lenses.
  - Blocked versus Waiting on You counts, and recurrences versus first occurrences.
  - Pull requests opened per repository, Partial Landing flags.
  - One line per answer arriving on a landed Card, on the Night it arrived.
  - Standing line: every un-adopted Card, individually, with its closed Feature, Block Reason and
    elapsed Nights (also rendered on the Card detail header). Cancelled Cards leave the line.
  - Standing line: the unmerged in-flight Feature, Nights held, `k of N` merged, Mainline Conflicts
    with paths.
  - Crashes and reclaims, permanent write failures, workspace-wide rate-limit events,
    `MainlineFetchFailed`, absent Nights detected, local-notification failures, anomalies.
  - Nothing spans Projects. No machine-wide bound line.
- **Spec** — `morning-report/write-the-night-summary`; `loop-state/*`; risks.md OQ12.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Rehearsal Nights of each kind (idle, quiet, crashed, partial) render the
  specified lines.

### [ ] P12.2 Instrumented rates
- **Work** — Report per Project, accumulating across that Project's Nights, with no pass/fail
  presentation and no cross-Project figure: share of green Cards accepted without reopening the
  diff; share of Nights ending with at least one pull request per touched repository; proximity to
  each Bound; Nights started from an empty board; whether every retry landed on a different route;
  `author_supplied_citation_count`.
- **Spec** — `morning-report/report-the-instrumented-rates`; DR1; risks.md TD8.
- **Gate** — G-9 (first rate only).
- **Agent** — Opus 5 Medium.
- **Done when** — Rates computed from multi-Night rehearsal Journals match hand-computed values.

### [ ] P12.3 Feature roll-up
- **Work**
  - Derive the roll-up state from Card states and Repo Lane completion, with fallback to the Feature
    Issue's own state when there are no Cards.
  - Render the fixed sentence shapes for the running and closed halves, the zero-Card templates, the
    `no live Cards · <c> cancelled` absence case, and Mainline Conflicts beside the sentence.
  - State-sorted member list grouped by Repo Lane, with adopted, banked-answer and Cancelled
    markers; Cancelled at the bottom.
  - A single Blocked Card always dominates and is counted.
  - Hash-skip over the rendered block.
- **Spec** — `board-projection/maintain-the-managed-block` (second story); glossary → Roll-up;
  risks.md OQ31.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Rehearsal tests cover each lattice word, each template, and reposting when only
  lane completion, merged fraction, conflict, live set or Feature state changes.

### [ ] P12.4 Headless notification posting mode in the app
- **Work**
  - `Yellowhammer.app` accepts a one-shot headless launch that posts one local notification (Project,
    event, reason) under its own bundle identity, then exits. No window and nothing resident.
  - Notification permission request at setup, with Time Sensitive where available.
- **Spec** — `morning-report/notify-the-operator-of-exceptions`; risks.md OQ9.
- **Agent** — Opus 5 Medium.
- **Done when** — Launching the app headlessly with post arguments shows a notification and the
  process exits.

### [ ] P12.5 Exception notification from Acts
- **Work**
  - On Night opened, halted (with reason) and closed: write the event to the Night Card first, then
    invoke the headless app post naming the Project.
  - Fire and forget. Failure is logged to the Journal and never fails the Act or Night. No
    retry, acknowledgement, state or combined notification.
- **Spec** — `morning-report/notify-the-operator-of-exceptions`; system-overview → Notification
  behaviour.
- **Gate** — G-10.
- **Agent** — Fable 5.1 Medium.
- **Done when** — With notifications disabled or the app missing, an Act completes and logs the
  failure.

---

## Phase 13 — Setup & operations CLI

### [ ] P13.1 `yh setup`
- **Work**
  - Interactive and non-interactive modes (`--init`, `--config <path>`).
  - Generate the machine-wide file and per-Project files with defaults.
  - Linear authorization, provisioning (P5.3), Linear project check or creation.
  - Notification permission registration through the headless app.
  - Routing warnings for entries with no fallback or a single CLI.
- **Spec** — risks.md OQ13 Facet 1 and Facet 3; `bounds/bound-unanswered-nights` (defaults).
- **Agent** — Fable 5.1 Medium.
- **Done when** — On a clean user account, `yh setup --init` produces a configuration that passes
  validation, and provisioning is idempotent.

### [ ] P13.2 Scheduled job generation
- **Work**
  - Generate three `launchd` user LaunchAgents per Project
    (`com.summerhammer.yellowhammer.<project>.<act>.plist`) invoking `yh <act> --project <id>`, with
    staggered calendar intervals across Projects.
  - `--install-jobs` installs and loads them. `--export-jobs` writes plists or cron lines without
    installing.
  - Confirm the invocation works under `launchd`'s bare environment (PATH to `git`, the CLIs and
    Orca ADE).
- **Spec** — `shift-scheduling/overview`; risks.md OQ13, OQ44, OQ53.
- **Gate** — G-7.
- **Agent** — Fable 5.1 Medium.
- **Done when** — Installed jobs fire `yh` on a developer machine at the scheduled times, and the
  event log shows each Act.

### [ ] P13.3 `yh doctor` / `yh validate`
- **Work** — Validate configuration, run probes, check git repositories, verify Linear credentials,
  inspect `launchd` job status, detect orphaned LaunchAgents (`--fix` unloads and removes them after
  confirmation), and warn on routing entries with no fallback.
- **Spec** — risks.md OQ13, OQ52 Face 1.
- **Agent** — Opus 5 Medium, or Gemini Flash 3.8 Medium.
- **Done when** — Each check has a passing and a failing fixture. An orphaned agent is found and
  removed.

### [ ] P13.4 `yh status`
- **Work** — Per Project, on demand: last Journal run, `launchd` job state, sleep and wake history,
  and a diagnosis of a missed Night (sleep, missing or disabled job, pre-initialization crash). No
  cross-Project verdict.
- **Spec** — risks.md OQ12 Surface 3.
- **Agent** — Opus 5 Medium, or Gemini Flash 3.8 Medium.
- **Done when** — Each diagnosis is produced from a staged scenario.

### [ ] P13.5 `yh project remove <id>`
- **Work**
  - Refuse while an Act of that Project holds an active lease.
  - Unload and delete the three LaunchAgents.
  - Post a release comment on an in-flight Feature Issue. Never delete Linear issues.
  - WIP-commit and push dirty Worktrees, then remove Worktrees through Orca ADE.
  - Close any open Night in the Journal with reason `project_removed`. Keep the Journal file.
- **Spec** — risks.md OQ52 Face 1.
- **Agent** — Opus 5 Medium.
- **Done when** — A rehearsal Project is removed with every listed effect, and removal during a
  running Act is refused.

---

## Phase 14 — Yellowhammer app

> The app is a shell, never a host. A Night must run correctly with the app never opened or quit
> mid-Shift. It writes no Journal, holds no state, queue or triage step, and has no cross-Project
> view. Gates **G-5** and **G-6** must be closed before P14.4–P14.8.

### [ ] P14.1 App shell and Project scope
- **Work**
  - The app structure chosen in G-5.
  - Project Selector showing configured Project names only (no badges, roll-up words or counts).
  - Optional per-Project windows.
  - `yellowhammer://project/<id>` URL scheme.
- **Spec** — risks.md OQ52 Face 2; ooux/nav-flow.md → Multi-Project Navigation.
- **Agent** — Fable 5.1 Medium.
- **Done when** — The selector and deep link open the named Project. A UI test confirms no status is
  shown in the selector.

### [ ] P14.2 Setup wizard
- **Work** — The app-side path for everything `yh setup` does (P13.1–P13.2), including notification
  permission status stated once, without nagging.
- **Spec** — risks.md OQ13; system-overview → Notification behaviour.
- **Agent** — Opus 5 Medium.
- **Done when** — A clean account is fully set up through the app alone.

### [ ] P14.3 Configuration editing
- **Work** — Edit Projects, Repos, Spec Source (shown read-only as "read — this Project never writes
  it"), Bounds, base Routing Table and per-Project overrides, as TOML file edits that keep the file
  valid under P2.3. Direct TOML editing stays supported.
- **Spec** — system-overview → Integration Map (app edits Routing Table); ooux/nav-flow.md →
  Setup; risks.md OQ51.
- **Agent** — Opus 5 Medium, or Gemini Flash 3.8 Medium.
- **Done when** — Edits made in the app round-trip through the loader. Invalid edits are refused
  with the loader's message.

### [ ] P14.4 Agent CLI detail and Probe trigger
- **Work** — List declared CLIs with their latest Probe Result from the Ledger, and run a Probe on
  demand.
- **Spec** — system-overview → Yellowhammer app; `routing/add-an-agent-cli`.
- **Agent** — Opus 5 Medium, or Gemini Flash 3.8 Medium.
- **Done when** — A Probe started from the app writes a Ledger row shown in the list.

### [ ] P14.5 Journal reading (account behind a Card)
- **Work** — Read-only display of a Card's account from its Project's Journal (Attempts, Rounds,
  routes, Check output). Opening the Journal read-only is enforced.
- **Spec** — system-overview → Yellowhammer app; `CLAUDE.md` → Read-only on every Journal.
- **Gate** — G-6.
- **Agent** — Opus 5 Medium.
- **Done when** — Opening a Journal in the app while an Act writes it causes no write conflict and no
  modification.

### [ ] P14.6 Status view
- **Work** — The app equivalent of `yh status` (P13.4) and `yh doctor` findings, per Project.
- **Spec** — risks.md OQ12 Surface 3.
- **Agent** — Opus 5 Medium, or Gemini Flash 3.8 Medium.
- **Done when** — Staged scenarios give the same diagnoses as the CLI.

### [ ] P14.7 Recalibrate
- **Work** — For the active Project: view Bounds and this Night's proximity, re-set Bounds, and start
  a rehearsal Night.
- **Spec** — ooux/nav-flow.md → Global nav; risks.md OQ52 Face 2.
- **Gate** — G-6.
- **Agent** — Opus 5 Medium.
- **Done when** — A rehearsal Night started from the app runs as a normal invocation that survives
  quitting the app.

### [ ] P14.8 Nav Flow screens the app owns
- **Work** — Build whichever of Night Card, Feature detail and Card detail G-6 assigns to the app,
  without making the app where a decision is recorded.
- **Spec** — ooux/nav-flow.md; ooux/sketch-sheets.md; ooux/cta-matrix.md.
- **Gate** — G-6.
- **Agent** — Opus 5 Medium.
- **Done when** — Scope defined by G-6.

### [ ] P14.9 Shell-not-host verification
- **Work** — An automated check that runs a rehearsal Night with the app never launched, and another
  that quits the app mid-Act. Both Nights complete identically.
- **Spec** — system-overview → Yellowhammer app (hard constraint).
- **Agent** — Fable 5.1 Medium.
- **Done when** — Both runs produce equivalent Journals and Night Cards.

---

## Phase 15 — Rehearsal environment & end-to-end rehearsal

### [ ] P15.1 `[DevOps]` Scratch Linear environment
- **Work**
  - One scratch Linear team shared by all rehearsing Projects, one scratch Linear project each.
  - Provisioning run against it (P5.3).
  - A cleanup procedure that archives scratch issues between rehearsal runs without touching
    provisioning.
  - Scratch credentials stored per P5.1.
- **Spec** — system-overview → Environments.
- **Agent** — Sonnet 5 Medium, or Gemini Flash 3.8 Medium.
- **Done when** — A rehearsal Project can run against the scratch team repeatedly and be reset.

### [ ] P15.2 `[DevOps]` Throwaway repositories and fixtures
- **Work**
  - Scripted creation of throwaway local repositories (with local bare remotes) for a multi-repo
    Project, including a spec repository with addressable stories and goals.
  - Fixture result files for architect, worker (success, failure, question), reviewer (approve,
    request changes) and verification.
  - Scenario fixtures: predecessor merged or not, mainline moved or not, Transcription Block path
    touched, protected path, conflicting branch.
- **Spec** — system-overview → What a story may assert against a rehearsal Night.
- **Agent** — Opus 5 Medium, or Gemini Flash 3.8 Medium.
- **Done when** — One command builds the full fixture set from nothing.

### [ ] P15.3 Rehearsal scenario suite
- **Work** — Scripted end-to-end rehearsal Nights, each asserting only rehearsal-assertable
  properties:
  1. Idle first Night (no actionable spec).
  2. First Night authoring Feature 1 across three repos, build, land up to the rehearsal boundaries.
  3. Quiet Night: predecessor not merged; then merged; then partially merged.
  4. Mid-lane block with a Partial Landing announcement rendered.
  5. Waiting on You answered before landing; answered after landing (banked).
  6. `unanswered_nights_max` firing with a value of 1.
  7. Engine invocation killed mid-Card, then reclaimed.
  8. Outbox replay after a killed run.
  9. Protected Path refusal.
  10. Divergence at dispatch; Adoption success and refusal.
  11. Cancelled Card and reopen.
  12. Two Projects concurrently on one Mac sharing the scratch team, showing no cross-Project reads
      or writes.
  13. Configuration with two conflicting Projects plus one valid Project.
- **Spec** — system-overview → Environment Differences; every epic listed above.
- **Agent** — Fable 5.1 High.
- **Done when** — The suite runs from a single command and passes on a developer machine.

### [ ] P15.4 `[DevOps]` Rehearsal suite in automation
- **Work** — Run P15.3 on a schedule on a self-hosted Apple Silicon runner with Orca ADE installed
  and scratch credentials available, or add it as a required manual release-checklist step when no
  such runner exists. Publish Journals and Night Card links as artifacts.
- **Agent** — Sonnet 5 Medium, or Gemini Flash 3.8 Medium.
- **Done when** — A failed scenario blocks the release checklist.

---

## Phase 16 — Release engineering & first production Night

### [ ] P16.1 `[DevOps]` Signing identity and secrets
- **Work**
  - Provision the Developer ID Application certificate and a notarization credential (App Store
    Connect API key or equivalent) in the release machine's keychain and in CI secrets.
  - Document ownership, expiry dates and renewal.
- **Spec** — stack.md → Distribution; feasibility probes → Build and packaging.
- **Agent** — Sonnet 5 Medium, or Gemini Flash 3.8 Medium.
- **Done when** — The release job can sign and authenticate for notarization without manual input.

### [ ] P16.2 `[DevOps]` Release build configuration
- **Work**
  - Release configuration of both targets: hardened runtime, Developer ID signing, `yh` embedded in
    `Contents/MacOS` with Code Sign On Copy, `yh` Info.plist embedded so codesign uses its bundle
    identifier.
  - Final deployment target from G-2, applied equally to the project and the package.
  - Versioning scheme: marketing version and build number set from the release tag in CI.
- **Spec** — `CLAUDE.md` → Local choices (Build); stack.md → Platform Targets.
- **Gate** — G-2.
- **Agent** — Fable 5.1 Medium.
- **Done when** — A Release build from a tag carries the tag's version in both the app and `yh`.

### [ ] P16.3 `[DevOps]` Notarization, stapling and verification
- **Work** — A release job that: builds Release, signs, packages, submits for notarization, waits for
  the result, staples the ticket, and verifies with `codesign --verify --deep --strict`, `spctl
  --assess`, and `stapler validate`. It fails on any rejection and archives the notarization log.
- **Spec** — stack.md → Distribution.
- **Agent** — Fable 5.1 Medium.
- **Done when** — A tagged build produces a notarized, stapled artifact that passes all three checks.

### [ ] P16.4 `[DevOps]` Packaging and distribution
- **Work**
  - Package the notarized `.app` for direct download (disk image or archive), with checksums.
  - Publish release notes that list the spec commit the release was built against and the story IDs
    it covers.
  - Host the download on the chosen direct-distribution channel.
- **Spec** — stack.md → Distribution (direct, not Mac App Store).
- **Agent** — Sonnet 5 Medium, or Gemini Flash 3.8 Medium.
- **Done when** — A downloaded artifact installs on a clean Apple Silicon Mac with no Gatekeeper
  warning.

### [ ] P16.5 `[DevOps]` Update channel
- **Work** — Implement the update channel decided in G-14.
- **Gate** — G-14.
- **Agent** — Sonnet 5 Medium, or Gemini Flash 3.8 Medium.
- **Done when** — Defined by G-14.

### [ ] P16.6 `[DevOps]` Installed-product verification
- **Work** — On a clean Apple Silicon Mac with the release artifact:
  1. `Contents/MacOS/yh` runs under a bare environment.
  2. The headless notification post works from the installed bundle identity.
  3. `launchd` jobs generated by `yh setup --install-jobs` fire the installed `yh`.
  4. `yh doctor` passes with Orca ADE, at least one CLI and the production Linear identity.
  5. Quitting and never opening the app does not affect a scheduled Act.
- **Spec** — feasibility probes → Build and packaging; risks.md OQ9, OQ53.
- **Agent** — Opus 5 Medium, or Gemini Flash 3.8 Medium.
- **Done when** — The checklist is completed and recorded for the release.

### [ ] P16.7 Release checklist
- **Work** — A written checklist run for every release: CI green; probe drift check (P7.5) green;
  rehearsal suite (P15.3/P15.4) green; notarization verified; installed-product verification (P16.6)
  done; release notes with spec commit and story IDs; spec conflicts from P1.1 checked for new
  answers.
- **Agent** — Opus 5 Medium, or Gemini Flash 3.8 Medium.
- **Done when** — The checklist is committed and used for the first release.

### [ ] P16.8 First production Night
- **Work**
  - Configure one real Project with its real repositories, real Linear project and real
    subscriptions.
  - Confirm Bounds are set explicitly, with defaults treated as illustrative values.
  - Install scheduled jobs. Let one full Night run unattended.
  - In the morning, triage entirely from Linear. Record whether any terminal had to be opened: the
    one hard number in DR1 is zero.
  - Record observations for the open threshold questions (G-13, G-15) without changing values in the
    same step.
- **Spec** — DR1; `morning-report/triage-the-morning`; goals.md.
- **Agent** — Fable 5.1 High.
- **Done when** — One production Night has run and been triaged from the board, and the observations
  are filed.

---

## Traceability: story → steps

| Story ID | Steps |
|---|---|
| `shift-scheduling/fire-an-act-on-schedule` | P4.1, P4.3, P3.2, P13.2, P8.1 |
| `shift-scheduling/open-and-close-the-night-card` | P4.4, P5.7, P12.1 |
| `shift-scheduling/do-one-acts-work-and-exit` | P4.2, P3.3 |
| `loop-state/claim-and-heartbeat-a-run-lease` | P3.4, P8.4 |
| `loop-state/reclaim-an-expired-lease` | P8.10, P6.8 |
| `loop-state/reconcile-worktrees-at-act-start` | P6.8, P6.9, P6.6 |
| `loop-state/record-failure-cause-recurrence` | P8.8 |
| `board-projection/write-board-updates-through-the-outbox` | P5.4 |
| `board-projection/read-board-changes-by-delta` | P5.5, P11.2, P11.3 |
| `board-projection/maintain-the-managed-block` | P5.6, P12.3, P11.3 |
| `board-projection/check-card-readiness-at-dispatch` | P8.2, P6.4 |
| `routing/resolve-a-route-for-a-card` | P2.4, P7.6 |
| `routing/exclude-tried-routes-on-retry` | P7.7 |
| `routing/add-an-agent-cli` | P2.3, P7.2, P7.3, P7.4, P7.5 |
| `feature-authoring/select-the-next-feature` | P9.1, P9.2, P9.3, P11.5, P11.6 |
| `feature-authoring/author-the-cycle-and-card-dag` | P9.4, P11.5 |
| `feature-authoring/author-citable-definitions-of-done` | P9.5, P9.7, P8.2 |
| `feature-authoring/author-an-architectural-brief` | P9.6, P6.5, P8.2 |
| `graph-execution/allocate-a-worktree-per-graph-and-repo` | P6.7 |
| `graph-execution/run-a-card` | P7.1, P7.2, P8.4, P8.6, P8.7, P8.9 |
| `graph-execution/gate-a-card-on-the-repository-check` | P2.3, P8.5 |
| `graph-execution/handle-a-block-mid-graph` | P8.9, P10.4 |
| `bounds/bound-review-rounds-and-attempts` | P8.6, P8.7 |
| `bounds/bound-unanswered-nights` | P11.4, P2.3 |
| `bounds/escalate-a-question-to-the-operator` | P11.1, P11.2, P5.8 |
| `bounds/refuse-protected-paths-before-dispatch` | P8.3 |
| `landing/open-one-pull-request-per-repository` | P10.1, P10.2, P10.3, P10.4 |
| `landing/announce-a-partial-landing` | P10.4, P10.8, P6.2 |
| `verification/verify-a-feature-clause-by-clause` | P10.5 |
| `verification/return-a-feature-with-unmet-clauses` | P10.6 |
| `verification/archive-the-cycle-on-a-verified-feature` | P10.7 |
| `morning-report/write-the-night-summary` | P12.1 |
| `morning-report/report-the-instrumented-rates` | P12.2 |
| `morning-report/notify-the-operator-of-exceptions` | P12.4, P12.5 |
| `morning-report/triage-the-morning` | P10.8, P10.9, P12.3, P16.8 |
