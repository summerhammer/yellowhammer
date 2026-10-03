# Refactor Linear to per-Project authorization — roadmap

This roadmap replaces the one machine-wide Linear App Installation with a registry of App
Installations that each Project selects from. It is separate from `implementation-roadmap.md` and
does not renumber it; that file gets one line linking here.

**Spec** — at `ab837d1`. Rulings: risks.md → *Per-Project Linear Workspace Ruling* (OQ109,
`8463b35`) and *Vendor-Named Configuration Tables Ruling* (OQ110, `55ceb34`). Stories:
`board-projection/install-the-linear-app` (the main contract), `shift-scheduling/diagnose-the-installation`,
`app/add-a-project-via-the-setup-wizard`, `app/land-on-the-sidebar-and-pulse`,
`board-projection/provision-the-board`, `board-projection/read-board-changes-by-delta`,
`board-projection/write-board-updates-through-the-outbox`, `loop-state` overview,
`shift-scheduling/fire-an-act-on-schedule`, `shift-scheduling/do-one-acts-work-and-exit`;
`docs/tech/stack.md#configuration-schema`. Read the ruling and the story before each step.

## What changes

- **Machine file.** `[linear]` → zero or more `[board.linear.installations.<name>]` tables
  (`credential`, `workspace`, `app_user`, `operator`). Zero is valid. Two entries with one
  `workspace` are refused. A top-level `[linear]`, and any key directly under `[board.linear]`,
  are unknown keys. No migration and no named legacy error.
- **Project file.** Exactly one `[board.<vendor>]` table; v1 accepts only `linear`.
  `[board.linear] installation = "<name>"` is required. **The Linear project id moves too**:
  top-level `linear_project` → `[board.linear] project` (OQ110 item 3: vendor-specific Project
  settings belong under that table). The key name is ours — raise it as a spec gap.
  An `installation` naming no registry entry refuses that Project only (OQ79 path).
- **Per installation**: token pair, refresh lock, Operator identity, Linear budget, authorization
  halt, `yh doctor` Check 4. A Project's installation is fixed for its life.
- **Journal** records the Linear workspace ID it was built against (`journal-schema-2`, edited in
  place). Every existing Journal is refused and recreated.
- **Deleted, not adapted** (the spec removed them as unreachable): `.legacyLinearClientID`,
  `removingLegacyLinearClientID`, the client-id repair in `Setup+MachineFile`, doctor's legacy
  check, and the one-workspace-per-Mac refusal in `Setup+LinearAuthorization.swift:206–215`
  (`.differentWorkspace` now means only OQ109 item 13, a re-connect approved for another workspace).

## Local choices (this repo's, not the spec's)

- **CLI surface.** `yh setup --installation <name>`: selects the installation for `--init`, targets
  a re-connect for `--install-linear`, and scopes `--print-choices` (`SetupOptions.swift:112–166`
  must allow it there). `--linear-credential` is removed. `yh config operator --installation <name>
  <user-id>` (spec-named; `--installation` required when more than one exists). `yh config
  remove-installation <name>` (the spec names none; Settings needs one that deletes the Keychain
  items). Raise the last as a spec gap.
- **Credential reference** `keychain:linear-<name>`: derived from the local name, which is fixed
  once written, so the Keychain account never needs renaming.
- **Refresh lock** one file per installation, `linear-token-<name>.lock`, beside today's
  `MachineLock` path.
- **Workspace name** is not stored (no spec key). `yh doctor --check linear --json` reads it per
  installation and reports it in its row; the UI falls back to the local name.
- **Drafted, pending sponsor — all built** (user decision 2026-10-03): editable local name at
  connect; refusals and records name the Projects / the workspace; an installation connected in a
  cancelled wizard stays; membership check, team recommendation and rehearsal scratch team are per
  installation; a re-connect returning an already-registered workspace keeps its Operator identity
  and selects it; `[info]` doctor tag; Health opens the Linear workspaces list for the two
  installation flags; a skipped release comment counts as a succeeded removal step.

## Every step

- **The bridge.** L1.1 changes `MachineConfiguration`'s shape, which breaks machine-only consumers
  (setup install, `--print-choices`, doctor Check 4, the app's `OperatorIdentityModel`,
  `SetupReadiness`). L1.1 keeps them compiling through one temporary accessor,
  `MachineConfiguration.soleLinearInstallation` (nil unless exactly one entry). Each later step
  removes its consumers' uses. **L3.2 deletes it**; its Done-when greps for it.
  Project-scoped consumers do not use the bridge: they resolve `machine.linearInstallation(for: project)`
  from L1.1 on.
- **Both whole-file renderers move with the decoder**, in the same commit:
  `MachineConfiguration.renderedTOML` (used by `BaseRoutingTableModel`, `AgentCLIModel`, setup's
  first write) and `ProjectFileDraft.renderedTOML` (Settings → Configuration, Recalibrate,
  `writeBounds`). Otherwise an unrelated Settings save erases the registry or `[board.linear]`.
- **Names.** Glossary terms verbatim: App Installation, Operator identity, Project, Linear
  workspace. UI copy says "Linear workspaces".
- **Sidekicks.** Sonnet (`model: sonnet`) for every cross-module brief; slice wide briefs and resume
  the same agent with SendMessage. Every brief bans `git checkout`, `git restore` and `git stash`.
  The lead writes actor/concurrency tests and runs UI tests itself. Verify sidekick claims (lint,
  test counts) yourself.
- **Done when**, in addition to each step's line: `swift test --package-path
  Packages/YellowhammerKit` is green; the app builds; `swiftlint lint --strict` adds no new
  violations against HEAD; the cited ACs are listed met or explicitly not met; `Spec:` lines cite
  `ab837d1`.
- One step is one layer in a `gh stack`, on top of any open stack. Mark `[x]` in its own commit.
- **A breaking change.** A `config.toml` or Project file that loads today is refused after L1.1.
  L1.1's commit and pull request are `feat(config)!:` with a `BREAKING CHANGE:` footer naming the
  new tables, so release-please bumps the version accordingly.
- **Do not install a build containing L1.1 on this Mac before the L4.1 re-connect.** L4.1's first
  step needs the *current* build to remove the `yellowhammer` Project; a newer build refuses its
  configuration.

---

## Phase L1 — Configuration and the engine

### [x] L1.1 The registry and the Project's selection in `Config`

- **Work**
  - `LinearInstallation` value (name, credential, workspace, appUser, operator) and
    `MachineConfiguration.linearInstallations` replacing the four flat fields. Decoder:
    root allow-list `board` instead of `linear`; under `board` only `linear`; under `board.linear`
    only `installations`; per-entry required keys; duplicate `workspace` refused; zero valid.
  - `ProjectConfiguration`: `[board.linear]` with `installation` and `project` (replacing
    `linear_project`); exactly one `[board.<vendor>]`; `[board.linear.installations]` refused in a
    Project file. Pass the registry's names into `ProjectConfigurationDecoder` as
    `declaredCLIAdapters` is passed, so a missing installation lands on the refused-Project path.
    The lenient removal load (`loadLeniently`) accepts a name missing from the registry (item 10)
    but still refuses a missing `installation` key.
  - Line-edit writers in `ConfigurationRendering.swift` address
    `[board.linear.installations.<name>]` (quoted names included): set operator, add/replace an
    installation. Both whole-file renderers carry the registry and `[board.linear]`.
  - `machine.linearInstallation(for: project)`; rewire `BoardBinding.makeLinearAdapter`,
    `RootCommand:84` (Operator identity) and `ProjectRemoveCommand` to it.
  - The bridge for machine-only consumers; setup's install keeps working for one installation.
  - Delete the legacy client-id error, repair path and doctor check.
  - Rewrite every TOML fixture (`Tests/ConfigTests/Fixtures/**`, `ConfigurationDirectory.machineFile`,
    `ConfigurationEditingFixtures`, EngineStub `--init` output, UI test fixtures) to the new shape.
    UI test fixtures change in this layer so the app's tests still load.
- **Spec** — `install-the-linear-app` (*What setup keeps*); `stack.md#configuration-schema`;
  OQ109 items 3, 11; OQ110 items 2–4.
- **Lead** — Opus 5.5 High. Designs the types, the bridge and the decoder rules.
- **Sidekick** — Sonnet, sliced: (a) types + decoders + tests, (b) writers + renderers + tests,
  (c) fixture rewrite, (d) consumer rewiring.
- **Done when** — Tests cover each refusal (unknown `[linear]`, flat keys under `[board.linear]`,
  wrong-file keys, duplicate workspace, zero/two `[board.<vendor>]`, unknown vendor, missing
  `installation`, name not in registry refusing only that Project); zero installations loads; a
  routing or CLI save keeps the registry; a Configuration save keeps `[board.linear]`; an Act binds
  the Project's own installation's credential and Operator.

### [x] L1.2 One lock, budget and halt per installation

- **Work** — `MachineLock` keyed by installation (`linear-token-<name>.lock`); two Projects on one
  installation still make one refresh, on two installations never wait. `AppInstallationTokenRefresh`
  and its Journal payload carry the installation name and workspace ID (payload keys only; no
  schema change). The halted notification names the workspace and says to re-connect it (`yh setup`
  Linear step or Settings → Linear workspaces) — `EngineInvocation+ExceptionNotification.swift:119`.
  Rate-limit records say installation-wide and name the workspace. Project removal: a missing
  installation skips the release comment, reports it, and counts as a succeeded step.
- **Spec** — `install-the-linear-app` (*Keeping it alive*, *When it stops working*);
  `read-board-changes-by-delta`; `write-board-updates-through-the-outbox`;
  `shift-scheduling/fire-an-act-on-schedule` (removal); OQ109 items 8, 10.
- **Lead** — Opus 5.5 High; writes the two-process lock tests.
- **Sidekick** — Sonnet for payload, copy and removal.
- **Done when** — Two processes on one installation make one token request; on two installations
  neither blocks; the refresh event decodes with the installation; removal with a missing
  installation exits successfully and reports the skipped comment.
- **Status** — Done on 2026-10-03 (`827d740`). `MachineLock.defaultFileURL(homeDirectory:installation:)`
  gives `linear-token-<name>.lock` (name percent-encoded, so injective and path-safe); setup's token
  store seam takes the `LinearInstallation`. A Domain `AppInstallationLabel` (local name, workspace
  ID) rides on `ActBoard` into the Engine: the refresh record and its payload carry `installation` and
  `workspace` (decoding requires both; L1.3 refuses older Journals), `RateBudgetExhausted` says
  `installation-wide` and names both, and the halt notification names the workspace by its local name
  (OQ117: the display name is not stored and cannot be read while Linear refuses). Removal skips the
  comment only for a *missing* installation; a present but refused one still fails (OQ119).
  `InstallationRefreshLockProcessTests` run a python child holding the real per-installation path.
  ACs met: *Keeping it alive* (one lock per installation; the lock holds no state); *When it stops
  working* (the copy names the workspace, as drafted); the delta-read and Outbox rate-limit records
  (installation-wide, workspace named as drafted); removal's item 10 and its drafted
  succeeded-step rule. Not touched here: doctor's own re-connect copy (`Doctor+Linear.swift`) is L2.3's.
  `Spec:` lines cite `d04d9c2`, not `ab837d1`: OQ117 and OQ119, which shape the halt copy and the
  removal skip, exist only there.

### [x] L1.3 The Journal records its Linear workspace

- **Work** — Edit `journal-schema-1` in place to `journal-schema-2`, adding the workspace ID,
  written when `EngineCommand` creates the Journal from the Project's installation. Engine and app
  refuse the old schema (existing behaviour). Setup reads a kept Journal read-only and refuses a
  reused Project id whose Journal names another workspace (asks for a new id or to archive the
  Journal); same workspace reopens it (OQ52).
- **Spec** — `loop-state` overview; `add-a-project-via-the-setup-wizard` (*Reused Project id*);
  OQ109 item 12.
- **Lead** — Opus 5.5 High. **Sidekick** — Sonnet.
- **Done when** — Tests: a new Journal holds the workspace; a different-workspace re-add is refused
  by `yh setup --init`; a same-workspace re-add reopens; the app refuses a schema-1 Journal.
- **Status** — Done on 2026-10-03 (`7a4ea32`). `project_state.linear_workspace` (NOT NULL) is
  written in the same insert as `outbox_salt`, from a migrator built with the workspace, so a
  Journal is never without one; a migration run with none throws `linearWorkspaceRequired`.
  `JournalStore.open(…, linearWorkspace:)` is the only creating open (`RootCommand` passes the
  Project's installation's workspace); abort, stop and removal use the new non-creating
  `openExisting`, so removal still works with a missing installation. An existing Journal keeps its
  workspace: the engine neither compares nor overwrites it. **Not built**: an engine-side refusal
  when the Project's installation names another workspace than its Journal (reachable only by
  hand-editing `installation`; no spec rule). Setup's check sits in `writeProject` after the
  kept-Project-file guard and before any Linear write; besides a different workspace it also
  **refuses a kept Journal it cannot read** (a schema-1 Journal included), since its workspace cannot
  be verified and every Act would refuse it. The spec is silent on that case; it is a local choice.
  Test overloads in each test target keep the old `open` signatures with fixture workspace
  `workspace-1`. ACs met: `loop-state` (the Journal records the workspace at creation; setup reads
  it); the wizard's *Reused Project id* for `yh setup` (refused / reopened, `--init` and
  interactive); OQ109 item 12. Not met here: the wizard showing the refusal on its Project step is
  L3.2's.

## Phase L2 — `yh`

### [ ] L2.1 `yh setup` against the registry

- **Work** — Order inverts: exchange → read workspace (ID, name, URL key) → look the workspace up
  in the registry → **re-connect** (replace tokens in place, keep name and Operator) or **new
  entry** (name = proposed URL key, editable; then the required Operator choice) → write the
  Keychain item under that entry's credential. `--installation <name>` on `--install-linear`
  re-connects that entry; approval for a different workspace discards the tokens and names the
  approved workspace (item 13). "Connect another" returning a registered workspace is a re-connect.
  `--init --installation <name>` writes `[board.linear]`. `--print-choices` lists installations
  (local name, workspace, Operator) in `SetupChoices`, and with `--installation` reads that
  workspace's members, teams and Linear projects. Interactive `yh setup` lists installations plus
  *Connect another Linear workspace…*, or connects straight away when there are none. The team
  recommendation names only the teams of Projects on that installation. Membership-first runs
  against the Project's own installation. Remove the bridge from setup.
  `Domain/SetupInvocation` follows (`--installation` replaces `--linear-credential`); the app keeps
  building.
- **Spec** — `install-the-linear-app` (*The install*, *Choosing*, *Re-connecting*, *Team access*);
  `provision-the-board`; OQ109 items 1, 4, 5, 13.
- **Lead** — Opus 5.5 High; designs the reordered install. **Sidekick** — Sonnet, sliced (install
  flow / `--init` / `--print-choices` / interactive).
- **Done when** — Stub-transport tests: new workspace adds an entry; same workspace replaces tokens
  only; re-connect to another workspace leaves the entry and Keychain untouched; `--init` writes the
  selection; `--print-choices --installation` is scoped. Setup installs into the scratch workspace.

### [ ] L2.2 `yh config operator` and `yh config remove-installation`

- **Work** — New `config` command group. `operator --installation <name> <user-id>` (required when
  more than one installation; validated against that workspace's candidates; forward-only).
  `remove-installation <name>`: refused while any Project file names it (refusal names them), or any
  Project file fails to decode (names the file); otherwise deletes the entry and its Keychain items
  and says the app stays installed in Linear.
- **Spec** — `install-the-linear-app` (*Removing an installation*); `diagnose-the-installation`;
  OQ66 as amended; OQ109 items 7, 8, 14.
- **Lead** — Opus 5.5 Medium. **Sidekick** — Sonnet.
- **Done when** — Each refusal and the success path are tested; the doctor message that named the
  missing `yh config operator` is now true.

### [ ] L2.3 `yh doctor` Check 4 per installation

- **Work** — Check 4 runs per installation (Keychain, authorization under that installation's lock,
  Operator), each finding naming the installation, its workspace and the Projects it serves. An
  unreferenced installation is `[info]` (new tag, outside the tally and exit code). A Project naming
  a missing installation is a failure for that Project. Board provisioning uses the Project's
  installation. JSON rows gain `installation` and `projects`, and the workspace name. Remove the
  bridge from doctor.
- **Spec** — `diagnose-the-installation`; OQ109 item 8.
- **Lead** — Opus 5.5 Medium. **Sidekick** — Sonnet.
- **Done when** — Tests for each finding with two installations; the JSON row shape is pinned by a
  test the app's decoder also uses.

## Phase L3 — The app

### [ ] L3.1 Settings → General → Linear workspaces

- **Work** — Replace the Linear and Operator identity sections with a **Linear workspaces** list:
  local name, workspace name, Operator identity; per workspace re-connect, remove (with the
  stays-installed-in-Linear copy and the refusals) and change the Operator; plus connect another.
  `LinearInstallationModel` takes an optional installation name. `OperatorIdentityModel` becomes
  per installation and saves through `yh config operator`. Remove the bridge from the app's Settings.
- **Spec** — `land-on-the-sidebar-and-pulse` (*Linear workspaces*); `install-the-linear-app`;
  OQ109 item 9.
- **Lead** — Opus 5.5 High; runs `LinearSettingsUITests` itself. **Sidekick** — Sonnet for the
  views and models; EngineStub grows `--installation`, `config` and per-installation doctor rows.
- **Done when** — UI tests: two workspaces listed; re-connect; remove refused while a Project uses
  it; change Operator records `config operator --installation`.

### [ ] L3.2 Add Project — the Linear step and readiness

- **Work** — The Linear step lists installations plus *Connect another Linear workspace…*, and
  connects straight away when there are none; the choice goes into `AddProjectDraft` and
  `--installation`. Teams and Linear projects are fetched per installation. `SetupReadiness` drops
  `linearInstallation` and `operatorIdentity` (both now belong to the Linear step); it keeps
  `agentCLIRoute`. A reused-id refusal (L1.3) shows on the Project step. An installation connected
  in a cancelled wizard stays. **Delete `soleLinearInstallation`.**
- **Spec** — `add-a-project-via-the-setup-wizard` (*The Linear step*, *Reused Project id*).
- **Lead** — Opus 5.5 High; runs `AddProjectUITests` itself. **Sidekick** — Sonnet.
- **Done when** — `grep -rn soleLinearInstallation` finds nothing; UI tests cover choosing a listed
  installation, connecting another, and the empty registry going straight to connecting.

### [ ] L3.3 The Project's workspace and its Health

- **Work** — Settings → Project → Configuration shows the workspace and installation name
  read-only, and the Linear project under it. `OverviewModel` stops copying one set of Linear
  Health flags onto every Project: each Project gets only its installation's flags (from the L2.3
  row field). The two installation flags open Settings → Linear workspaces.
- **Spec** — `land-on-the-sidebar-and-pulse` (*CONFIGURATION*, Health).
- **Lead** — Opus 5.5 Medium. **Sidekick** — Sonnet.
- **Done when** — `HealthFlagReadTests` cover two installations; a UI test shows a revoked
  installation on its own Projects only.

## Phase L4 — Scripts, docs and this Mac

### [ ] L4.1 Scripts, runbooks and the live re-connect

- **Work** — `scripts/rehearsal-suite` (`suite_env.py:194` reads `[linear] operator`), its tests,
  `scripts/scratch-linear/`, `scripts/ci/tests/test_verify_installed.py`, `test_release_gate.py`,
  and the rehearsal scratch team per installation. Update `doc/linear-identity-runbook.md`,
  `installed-product-verification.md`, `release-checklist.md`.
- **This Mac re-connects from scratch** (user decision 2026-10-03): with the *current* installed
  build, `yh project remove yellowhammer` (unloads its LaunchAgents, posts the release comment);
  delete the `keychain:linear` item and the `[linear]` table. Install the new build, connect the
  scratch workspace, add the Project again. A workspace admin approves again. Update the
  scratch-environment memory afterwards.
- **Owed, recorded not implied:** the scratch environment has one workspace, so the live run proves
  one installation. Two-installation behaviour (separate budgets, locks, halts) is proved by tests
  only.
- **Spec** — `stack.md`; `system-overview.md#environments`.
- **Lead** — Opus 5.5 Medium; does the live steps. **Sidekick** — Haiku for the Python and docs.
- **Done when** — The rehearsal suite and CI Python tests pass; a rehearsal Night runs on the new
  configuration; the live re-connect is recorded here with the date.

## Spec gaps to raise (do not edit the spec)

- The key name `[board.linear] project` for the Linear project id (OQ110 item 3 implies the table;
  no key is named).
- No `yh` command is named for removing an installation; `--installation` on setup is unnamed.
- The workspace *name* has no source but a live read; the spec lists it in Settings and setup.
- Item 11's premise ("no installation exists yet") was false on the development Mac.
- OQ109's unsettled case — removal when the installation is present but its authorization is
  refused — stays under OQ77 as built (the comment step fails, the Project file is kept).
