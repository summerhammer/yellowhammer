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

### [x] L2.1 `yh setup` against the registry

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
- **Status** — Done on 2026-10-03 (`d7c0047`). `storeInstalled` decides before any write: a targeted
  re-connect approved elsewhere throws `.differentWorkspace` naming the approved workspace (nothing
  stored); a registered workspace re-connects (config.toml rewritten only if `app_user` changed); any
  other becomes a new entry. The proposed name is the URL key coerced to
  `LinearInstallation.isValidLocalName` (`^[a-z0-9][a-z0-9_-]*$`, now public in `Config`, not enforced
  by the decoder), suffixed `-2`, `-3`… if taken; interactive runs may edit it, asked before the
  credential is derived, so a cancel leaves no Keychain item. `--print-choices` always carries
  `installations` (name, workspace ID, `operator`; decoded `?? []`); without `--installation` it makes
  no Linear call and succeeds with zero entries. Non-interactive `--init`/`--config` with entries but
  no `--installation` runs no Linear step, and refuses `--project` or `--operator` without it.
  Interactive `yh setup` lists every entry (one included) plus *Connect another Linear workspace…*.
  `--linear-credential` is removed (`feat(setup)!`). ACs met: *The install* (Operator choice
  required after connect; team recommendation scoped to the installation's Projects); *Choosing an
  installation* (listing, `--installation`, connect another, none → connect, a registered workspace
  from connect-another re-connects and keeps the Operator); *What setup keeps* (URL-key name,
  editable); *Re-connecting a workspace* (both); *Team access* (membership-first per Project's
  installation, unchanged). **Not met here**: the listing shows the workspace ID, not its name —
  there is no live workspace-name read yet; L2.3 adds it for doctor and setup can reuse it. The app
  still selects through `soleLinearInstallation` (L3.1/L3.2). **Owed** (user decision 2026-10-03):
  the live install into the scratch workspace is proved by L4.1's re-connect, not run here. `Spec:`
  cites `d04d9c2` (OQ116 `--installation`, OQ117 workspace name exist only there).

### [x] L2.2 `yh config operator` and `yh config remove-installation`

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
- **Status** — Done on 2026-10-03 (`7f53624`). `yh config operator` reads only `config.toml`, so an
  invalid Project file does not block it; it validates against that workspace's members read as the
  installation's app user (a revoked installation names the re-connect), rewrites only that table, and
  says the change applies from the next Act with no reassignment. Setup and it share
  `OperatorIdentityEditing` (exclusion message, validated write). `remove-installation` loads with
  `Configuration.loadLeniently` (a Project naming some *other* missing installation does not block
  it) and has no confirmation prompt. **Local choice:** every entry in `invalidProjects` refuses as
  "failed to decode", including a Project refused only for a working-Repo conflict, whose
  `installation` is then not read. It deletes the Keychain item under the installation's refresh lock
  *before* rewriting `config.toml`, so a failure between the two leaves an entry without tokens
  (doctor reports it), never an orphaned secret. The `linear-token-<name>.lock` file is left behind
  (not a Keychain item; it holds no state). Doctor's missing-Operator warning now names
  `yh config operator --installation <name>`. ACs met: *Removing an installation* (both refusals,
  naming Projects / the file; deletes the entry and Keychain item; says the app stays installed in
  Linear; the OQ116 command); `diagnose-the-installation` *Missing Operator identity* (the command it
  names exists); OQ66 item 4 as amended (per installation, same list and validation, forward-only);
  OQ109 items 7, 8, 14. **Not met here**: Settings' *Remove* running the command is L3's. `Spec:`
  cites `d04d9c2` (OQ116 exists only there).

### [x] L2.3 `yh doctor` Check 4 per installation

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
- **Status** — Done on 2026-10-03 (`02323a3`). Check 4 runs per registry entry in registry order:
  Keychain → authorization (`workspaceMembers()`, refreshed under that installation's lock) → Operator,
  then an `[info]` line when no Project uses it, then a team-membership finding per Project it serves.
  Each finding's message is prefixed `installation <name> (workspace "<name>"; Projects a, b): `; the
  name comes from a new Board Port read, `BoardProvisioning.workspace()` (ID, name, URL key, the
  `organization` query), made before authorization; a revoked installation fails both reads and is
  named by its local name alone (OQ117). `yh doctor --json` rows are one shared `Domain.DoctorFindingRow`
  (encoded by `DoctorCommand`, decoded by `HealthFlag.read` and `LinearInstallationModel`), pinned by
  `DoctorFindingRowTests`; rows gain optional `installation`, `workspace`, `workspaceName`, `projects`,
  so today's four-field rows (the UI-test `EngineStub`) still decode. `[info]` (JSON `"info"`) is
  outside the tally and the exit code. **Missing installation**: the strict load already refuses such
  a Project (Check 1, `undeclaredLinearInstallation`); Check 4 *also* reports a `linear` failure, subject
  `project`, naming the Project, the missing name and both fixes, so `--check linear` sees it — one
  fault, two failure lines. Its subject is not `installation`, so Health does not show it as a revoked
  installation. **Local choices:** under `--project`, an installation's findings are kept only when it
  serves that Project (an unreferenced installation's `[info]` drops); team findings use subject `team`.
  ACs met: *Per installation* (names installation, live workspace name, Projects); *Unreferenced
  installation* (`[info]`, names `yh config remove-installation`); *Missing installation*; *No
  installation* (both cases); *Keychain tokens*, *Linear authorization*, *Operator identity* (missing
  names `--installation <name>` and the Projects; stale; valid), each per installation; the `[info]`
  output tag; OQ109 item 8. **Not met**: *Board provisioning* is only half built — doctor never had this
  check; L2.3 adds the membership half through the Project's installation (non-member team names the
  Settings → Members fix; `FORBIDDEN` is a permission refusal, never "not visible", OQ80), but does
  **not** verify that every provisioned or mapped item exists. The copy names Settings → Linear
  workspaces, which L3.1 builds; the app still reads the first `authorization` row (L3.1) and copies
  Health flags onto every Project (L3.3). Not run live: the workspace read and membership check are
  proved on stub transports and fakes only. `Spec:` cites `d04d9c2` (OQ116's command in the `[info]`
  line and OQ117's live name exist only there).

## Phase L3 — The app

### [x] L3.1 Settings → General → Linear workspaces

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
- **Status** — Done on 2026-10-03 (`2c3095f`). `LinearWorkspacesModel` (owned by `SettingsWindow`) reads
  `config.toml` and the Project files and writes nothing; a row shows the workspace name from
  `yh doctor --check linear --json` (`Domain.LinearInstallationStatus`, the local name when none was read,
  OQ117), the Projects that name it, the doctor's status, the Operator identity, and *Re-connect…*
  (`yh setup --install-linear --installation <name>`, locally or by admin link), *Change Operator…*
  (`yh config operator --installation <name>`, `Domain.ConfigInvocation`, pinned against the parsers) and
  *Remove…* (`yh config remove-installation <name>`; the confirmation says the app stays installed in
  Linear, and `yh`'s refusal or success lines are shown verbatim). *Connect another Linear workspace* is
  the untargeted install; a new entry without an Operator identity opens its candidates at once.
  Child models are keyed by local name and survive reloads. `LinearInstallationModel` takes the
  installation name at init. **Local choice / fix:** the doctor read runs once per window, on the pane's
  first appearance, in a model-owned task — a view `.task` was cancelled when navigation recreated the
  pane, which ended the read with nothing to retry it (caught by the UI test). It is not re-read on app
  activation; `config.toml` is. ACs met: OQ109 item 9 (connect, re-connect, remove, change the Operator,
  per workspace); *Removing an installation* (Remove runs the command; both refusals and the
  stays-installed copy reach the UI); *Re-connecting a workspace* (targeted by `--installation`);
  *Choosing* — fixed for the Project's life (no Settings control changes it); the Settings half of the
  OQ117 workspace name. UI tests: two workspaces listed with names, Operators and Projects; re-connect
  runs only that installation; remove refused while `alpha` uses it; remove succeeds with the
  stays-installed copy; Change Operator records `config operator --installation scratch user-op`.
  **Not UI-tested**: connect-another's follow-on Operator fetch; an Operator save `yh` refuses; removal
  refused because a Project file fails to decode (the same verbatim-lines path). **Not met here**: the
  wizard still builds an untargeted `LinearInstallationModel`, reads the first `authorization` row and
  uses `soleLinearInstallation` (L3.2); Health opening this list (L3.3). The editable local name at
  connect still has no headless form (spec gap above), so Settings' connect uses the proposed name.
  `Spec:` cites `d04d9c2` (OQ116's command and OQ117's live name exist only there).

### [x] L3.2 Add Project — the Linear step and readiness

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
- **Status** — Done on 2026-10-03 (`b4bca20`). The wizard owns a `LinearWorkspacesModel` (moved to
  `Features/Shared` with `OperatorIdentityModel` and a shared `OperatorIdentityRow`); the Linear step lists
  its rows (workspace name from the doctor read, else the local name; Operator identity) with nothing
  preselected, plus *Connect another Linear workspace…*, and shows the connect view at once when the registry
  is empty. `AddProjectDraft.linearInstallationName` is the choice; selecting another clears the teams, Linear
  projects and choices made from them, and `--print-choices --installation` runs per selection (a stale run is
  terminated and its answer dropped). A connect selects the new entry and opens its Operator candidates; the
  step's problems are, in order, no installation, none selected, no Operator identity, then the Linear
  project's. `SetupReadiness` keeps only `agentCLIRoute`. **Reused id:** the wizard opens each kept Journal
  (no Project file under its id) read-only and the Project step refuses a different workspace or an
  unreadable Journal, mirroring L1.3's `yh setup`; with no installation selected yet it says nothing.
  `soleLinearInstallation` is deleted. **UI-test harness:** the runner is sandboxed and cannot write `/tmp`,
  and the stub cannot write the runner's container, so the stub's connect and Operator save wait on a gate
  file in the container (`YH_STUB_GATE_DIR`) while the test makes the `config.toml` edit `yh` would make.
  ACs met (`add-a-project-via-the-setup-wizard`, *The Linear step*): the listing and selection written as
  `[board.linear] installation`; the Linear project chosen from that installation's workspace (OQ115, as
  drafted); connect another runs the install and the Operator choice, adds and selects it; no installation
  goes straight to connecting; a connected installation stays after Cancel and is listed next time
  (drafted); *Reused Project id* — refused / reopened on the Project step. UI tests: choosing a listed
  installation (`--print-choices --installation scratch`, `--init --installation scratch`); connect another,
  Operator saved, survives Cancel; empty registry connects, then completes with `--installation acme`;
  ports-busy, remote-approval and relay-unreachable connects select the new entry. **Not UI-tested**: the
  reused-id refusal (unit tests in `AddProjectDraftLinearStepTests` only); a refused Operator save in the
  wizard. The editable local name at connect still has no headless form (spec gap), so the wizard's connect
  uses the proposed name. `Spec:` cites `d04d9c2` (OQ115 and OQ117 exist only there).

### [x] L3.3 The Project's workspace and its Health

- **Work** — Settings → Project → Configuration shows the workspace and installation name
  read-only, and the Linear project under it. `OverviewModel` stops copying one set of Linear
  Health flags onto every Project: each Project gets only its installation's flags (from the L2.3
  row field). The two installation flags open Settings → Linear workspaces.
- **Spec** — `land-on-the-sidebar-and-pulse` (*CONFIGURATION*, Health).
- **Lead** — Opus 5.5 Medium. **Sidekick** — Sonnet.
- **Done when** — `HealthFlagReadTests` cover two installations; a UI test shows a revoked
  installation on its own Projects only.
- **Status** — Done on 2026-10-03 (`9e7b00c`). `HealthFlag.flags(in:for:)` filters the decoded `yh doctor --json`
  rows per Project. `OverviewModel` keeps the rows and fills each Project's Health from them. The stale
  Operator identity and App Installation revoked flags are kept only when the row's `projects` names the
  Project. `projects == []` (an installation no Project uses) and a missing `projects` are on no Pulse, never
  broadcast. Probe failures are machine-wide and stay on every Project. `linear`/`project` (a missing
  installation) is still not a flag. `HealthFlag.destination` sends the two installation flags to the new
  `PulseDestination.linearWorkspaces` (Settings → General) and a probe failure to the Project's entry. The
  Configuration tab gains a read-only **Linear** section: the workspace name, the installation's local name,
  and a fixed-for-life caption, with the editable Linear project field under them. The workspace name comes
  from the Settings window's `LinearWorkspacesModel` doctor read, which a Project entry now also starts (once
  per window). The local name is shown when that read has not run (OQ117). ACs met
  (`land-on-the-sidebar-and-pulse`, *Health*): the Operator identity and App Installation flags are those of
  the Project's own installation, naming its workspace (in `yh doctor`'s own message); other installations'
  flags are not shown; *drafted*: those two flags open Settings → Linear workspaces. Met in
  `add-a-project-via-the-setup-wizard`: a Project's **CONFIGURATION** tab shows the workspace and local name
  read-only. Tests: `HealthFlagReadTests` covers a two-installation fixture (`acme` revoked serving a and b,
  `scratch` stale serving c, an unused `old`, a row without `projects`, a probe failure). UI tests:
  `HealthGroupUITests` (revoked `acme` shows on `archive` and `owner`, not on `reader`, which uses `scratch`;
  the flag opens Settings → General's `acme` row) and `SettingsWindowUITests` (read-only workspace and
  installation rows). **Not UI-tested**: the Configuration tab showing a live workspace name rather than the
  local name, because no fixture stub answers `doctor --check linear`. `Spec:` cites `ab837d1`.

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
- **Status** — Scripts and docs done (`1bb36a8`, `d9aa33c`, `10222d0`); live re-connect done 2026-10-03.
  `scratch_linear.py`, the rehearsal suite, `release_gate.py record`, the shell-not-host harness and
  `verify_installed.py` read `[board.linear.installations.<name>]` and `[board.linear]`; `--installation
  NAME` selects one (default the sole entry; none, or several without it, refused). The suite passes it to
  `yh setup --init` and `scratch_linear.py reset`; `reset`/`check` refuse a Project on another
  installation. Found beyond the list: `verify_installed.py` matched doctor's old exact line; the
  shell-not-host harness read `linear_project`; the opt-in live Swift suites read Keychain account `linear`
  (now `YH_LINEAR_INSTALLATION` → `linear-<name>`). The runbook still described `client_credentials`; it is
  rewritten. **Live, 2026-10-03:** the old installed build removed `yellowhammer` (release comment
  posted); its schema-1 Journal is archived, not deleted; Keychain `linear` and `[linear]` removed. A
  local Release build (Developer ID, not notarized) was installed; `yh setup --install-linear --events
  json` registered `summerhammer` (same workspace); the Operator restored with `yh config operator`; the
  Project re-added with `--init --installation summerhammer --linear-project <same id>` (`protected_paths`
  restored by hand: `--repo` cannot carry them). `yh doctor --check linear` passes all three per-installation
  checks; `yh rehearse --project yellowhammer` ran author, build and land, exit 0, and the new Journal
  records the workspace. LaunchAgents are **not** reinstalled yet (awaiting the user's call). Python CI suites green
  (scratch-linear 34, rehearsal-suite 188, shell-not-host 45, verify_installed 33). **Owed:** the live
  rehearsal suite (`rehearsal_suite.py run`, ~45 min; it re-creates the `rehearsal-suite-a/-b` Projects
  removed 2026-10-01). Interactive `yh setup` cannot run under the `!` prefix (no stdin; prompts cancel).

## Spec gaps to raise (do not edit the spec)

- The key name `[board.linear] project` for the Linear project id (OQ110 item 3 implies the table;
  no key is named).
- No `yh` command is named for removing an installation; `--installation` on setup is unnamed.
- The editable local name at connect has no headless form: `yh setup --install-linear --events json`
  (the app's path) cannot take a chosen name, so L3.1/L3.2 need a flag the spec does not name.
- The workspace *name* has no source but a live read; the spec lists it in Settings and setup.
- Item 11's premise ("no installation exists yet") was false on the development Mac.
- OQ109's unsettled case — removal when the installation is present but its authorization is
  refused — stays under OQ77 as built (the comment step fails, the Project file is kept).
