# Linear board identity: Board Connections, storage, re-connecting, removal

Yellowhammer authenticates to Linear as its own Yellowhammer identity, through an **Board Connection** of its
Linear OAuth application in a Linear workspace — never as an Operator's personal API key. A personal
key silences Linear's self-action notification suppression, so Yellowhammer's own comments and
assignments would never reach the Operator's Inbox — see spec `system-overview.md` → *Why the board
identity is its own subsystem concern* and the Linear feasibility probe (*Identity & notifications*).

The machine holds a registry of Board Connections, zero or more, one per Linear workspace. Each
Project selects one by name. A developer Mac can hold a scratch installation and a production
installation at once; nothing is shared between them (see *Storage*). The earlier rule that a machine
talks to exactly one workspace, through a single `keychain:linear` reference, is gone, and so is the
`client_credentials` / `client_id` identity it went with.

## Connecting a workspace

```sh
yh setup --install-linear
```

This opens the browser for a Linear workspace admin to approve the app. There is no client id and no
client secret to copy. The approval creates the Yellowhammer identity in that workspace; Yellowhammer then
stores the token pair and registers the installation (below).

- Re-connecting a workspace that is already registered replaces its tokens and keeps its local name
  and its Operator identity. `yh setup --install-linear --board-connection <name>` re-connects that one
  installation.
- The local `<name>` defaults to the workspace URL key and is fixed once written. Name it yourself
  with `yh setup --install-linear --board-connection-name <name>` (the app's name field passes the same
  flag). An invalid name, or one another installation uses, is refused before the browser opens. If
  Linear approves a workspace that is already connected, that installation is re-connected and the
  given name is discarded.
- Two entries with one workspace are refused.
- Choose which Linear teams the Yellowhammer identity joins on the install screen. The Yellowhammer identity must be a
  **member** of the team a Project provisions inside; "All public teams" does not make it one (see
  `../scripts/scratch-linear/README.md`).

## Storage

The machine-wide config file (`~/.config/yellowhammer/config.toml`) holds zero or more installations:

```toml
[board.linear.connections.<name>]
credential = "keychain:linear-<name>"
workspace = "<Linear workspace id>"
yellowhammer_identity = "<Yellowhammer identity id>"
operator = "<user id>"
```

`operator` is the Operator identity; it is optional until chosen. A top-level `[linear]` table is
refused. Zero installations is valid. Nothing in this table is a secret.

`credential` references the login keychain item `service = "dev.yellowhammer"`,
`account = "linear-<name>"`, resolved by `Config.KeychainCredentialStore`. The item holds the token
pair (access token, refresh token and expiry) as written by `yh setup --install-linear` and refreshed by
the engine. It is not a client secret. Never put it in the repo or a config file.

Each installation has its own Keychain item, its own refresh lock (`linear-token-<name>.lock`), its own
rate budget and its own authorization halt.

A Project file selects an installation in `projects/<id>.toml`:

```toml
[board.linear]
connection = "<name>"
project = "<Linear project id>"
```

`installation` is required and fixed for the Project's life. `project` is the Project's Linear project
(it replaces the old top-level `linear_project`). A Project file never carries credentials.

**Where installations live.**

- **Developer machines and CI** (GitHub Actions macOS runners, for adapter tests against the scratch
  workspace) use the **scratch** workspace's installation. CI has no persistent Keychain across runs,
  and no workflow step provisions one yet: the adapter tests are hermetic, and the live tests (below) are
  opt-in, so CI does not need an installation until a live test runs there.
- **The Operator's real daily-use machine** — wherever Yellowhammer manages real Projects — uses the
  **production** workspace's installation. A machine may also hold the scratch one; what matters is
  which installation each Project names.

## Choosing and changing the Operator identity

```sh
yh setup --print-choices [--board-connection <name>]
yh config operator --board-connection <name> <user-id>
```

`--print-choices` lists the Operator candidates and the teams the app can see, and writes nothing.
`yh config operator` changes one installation's `operator` key.

## Verifying

```sh
yh doctor --check linear [--json]
```

Check 4 reports one group per installation. An installation no Project names is reported `[info]`.

To confirm the Inbox behaviour, post one comment on a test issue as the app and confirm it triggers an
Inbox notification (`issueNewComment`) for the Operator — the concrete acceptance check for the
identity.

## Running the live adapter test

The Linear adapter's tests run offline against a stub transport. One test, `LinearScratchTests`,
talks to the real **scratch** workspace: it reads the installation's token pair, checks that `viewer`
resolves to the registered application rather than an Operator, and reads one page of the scratch
Linear project's issues. It is opt-in and skips cleanly when its inputs are absent:

```sh
YH_LINEAR_SCRATCH_TESTS=1 \
YH_LINEAR_INSTALLATION=<scratch installation's local name> \
YH_LINEAR_PROJECT_ID=<scratch-linear-project-id> \
swift test --package-path Packages/YellowhammerKit --filter LinearScratchTests
```

`YH_LINEAR_INSTALLATION` names the scratch Board Connection; the test reads its token pair from the
Keychain item `linear-<name>` and writes refreshed pairs back. There is no client id or secret in the
environment. Run it on a developer machine holding the scratch installation, never against production's.

## Re-connecting (token rotation)

The engine refreshes the token pair itself under the installation's refresh lock. Re-connect when that
no longer works (the doctor reports the installation's authorization as failing), on a compromise
suspicion, or on developer-machine offboarding:

1. `yh setup --install-linear --board-connection <name>`, and approve in Linear again. The tokens in that
   installation's Keychain item are replaced; its name and Operator identity are kept.
2. `yh doctor --check linear` to confirm the installation is healthy.
3. Installations are independent: re-connecting one never touches another.

The spec does not mandate a schedule.

## Removal and revocation

```sh
yh config remove-board-connection <name>
```

This is refused while any Project names the installation. Otherwise it deletes the entry from
`config.toml` and its Keychain item. The app stays installed in Linear; revoking it there is a
workspace admin's action in Linear's settings.

When the installation's authorization can never be restored (the workspace was deleted, or no admin
will approve again) and a Project still names it, `yh project remove` cannot finish while a Feature
is in flight. The exit is:

```sh
yh config remove-board-connection <name> --orphan-projects   # asks to confirm; --yes skips the prompt
```

It removes the entry and its Keychain item even while Projects name it, but only when a live check
finds the authorization refused. An absent Keychain item counts as refused. An unreadable Keychain
item or an unreachable Linear refuses it and exits 1. It is still refused while a Project file fails
to decode. Then run `yh project remove <id>` for each Project it lists: the release comment is
skipped and reported. To undo, re-connect the same workspace with
`yh setup --board-connection-name <name>` under the exact same local name. Do not delete a Project file
by hand: that skips the WIP Commit and push. Settings offers the same as **Remove Anyway…**.

## Provisioning (P5.3)

`Engine.BoardProvisioner` provisions what the board projection depends on. It is run by setup
(`yh setup`, P13.1) through `EngineCommand.BoardBinding.provisioning`. It only ever **creates**: it
never renames, moves, re-parents, archives or deletes anything already on the board.

For the Project's Linear project it verifies the Linear project exists. When it does not, it is
created only if setup names a team to create it in; otherwise it is reported `missing` and nothing
else is touched. The new Linear project's id must then be written to `[board.linear] project`.

Then, **once per team** the Linear project belongs to (Projects sharing a team share the result):

- the two custom workflow states, `Waiting on You` and `Blocked` (type `started`);
- the label group `Card Type` with `Feature Card`, `Work Card`, `Night Card`.

That is the whole footprint (board-projection/provision-the-board; roadmap P22.8). Every other state is the
team's **native** state, selected by workflow **category** and never by display name: Todo is the lowest-position
`unstarted` state, In Progress the lowest-position `started` one (Yellowhammer's own two are excluded), Done the lowest-position `completed` one, and Shelved the
`canceled` one. A position tie goes to the lowest state id. A team that lacks one of those categories is
reported as an incomplete step naming the category and the team; setup never creates a substitute. No
`Block Reason` or `Override` label group is provisioned: Block Reason is Card content, and the Card override
is one description field on each Work Card (P22.7). Yellowhammer makes no backward-compatibility commitment
before v1.0, so it reads nothing of an earlier taxonomy: when the shape of the board changes, the Operator
hard-deletes the local Journal and config and Yellowhammer's Linear labels and workflow states, then runs
setup again (see [#613](https://github.com/summerhammer/yellowhammer/issues/613)).

Every item is reported `present`, `created`, `collision` or `blocked`. A label of the same name
anywhere the team can see it — a workspace label, a team label, or a label in another group — is a
**collision**: reported, never overwritten, and that one label is not created. (The feasibility
probe's workspace already had a workspace-level `Feature`.) A non-group label holding a group's name
blocks the whole group. A workflow state's uniqueness is scoped to (name, type), not name alone (a
live probe found a team-owned `Released` of type `completed` coexisting with ours of type `started`).

### Persisted ids and the Board Mapping

A matching name alone never adopts a state. Setup records, in the Project's Journal, the id of each of the two
custom states and of each `Card Type` label with its source: `provisioned` (setup created it) or `mapped` (the
Operator named it). Later Acts reuse the recorded id and re-verify that it exists with the right category. A
same-name `started` state with no recorded id and no mapping is a **collision**: delete it in Linear, or map it
on purpose, and `yh doctor` prints the exact lines to do so. Nothing writes the mapping for the Operator;
`yh doctor --fix` never edits the Project file. The lines look like:

```toml
[board.linear.mapping]
waiting_on_you = "<workflow state id>"
blocked = "<workflow state id>"
```

`[board.linear.mapping]` (in the Project's file) selects existing Linear objects by id: the workflow-state keys
`waiting_on_you`, `blocked` (both must be `started`), `unstarted`, `started`, `completed`, `canceled`, and the
`Card Type` label keys `feature_card`, `work_card`, `night_card`. Each id must exist with the right category, no
id may serve two meanings, and Projects on one Linear project must declare compatible mappings. A mapping that
fails is reported as a step setup could not do; nothing is inferred from a name in its place. Any other key
(`block_reason`, `override`, `kept_in_flight` and `abandoned` included) is an unknown key and fails the load.

The Journal is per Project, so a second Project on a team whose states another Project created has no recorded
id: it reports the same collision until it maps them.

### Running provisioning against the scratch workspace

Opt-in. It provisions the scratch Linear project's teams twice and asserts that the second run
changes nothing and reports the same collisions:

```sh
YH_LINEAR_SCRATCH_TESTS=1 \
YH_LINEAR_INSTALLATION=<scratch installation's local name> \
YH_LINEAR_PROJECT_ID=<scratch-linear-project-id> \
swift test --package-path Packages/YellowhammerKit --filter BoardProvisionerScratchTests
```

## Scratch environment (P15.1)

Between rehearsal Night runs, the scratch Linear team's issues need archiving and each rehearsing
Project's Journal needs clearing, without touching provisioning. See
`../scripts/scratch-linear/README.md` for the runbook and `scripts/scratch-linear/scratch_linear.py`
for the `check`/`reset` tool.

## Phase 23 upgrade: v0.24.0

Before the first Act on v0.24.0, complete these steps for **every Project**, including Projects used
only for rehearsal. This pre-1.0 release changes the Journal to `journal-schema-24` and adds periodic
`author` firings. The Ledger is retained.

1. Choose a maintenance window with **no Act running**, and prevent scheduled or manual Acts from
   starting until the reset and job regeneration are complete. Quit the app while replacing Journals.
   Check the Project's jobs with `launchctl list` and check for running `yh` processes; a sleeping job
   alone is not evidence that no manual Act is running. Never unload or regenerate a running Act's
   LaunchAgent ([#407](https://github.com/summerhammer/yellowhammer/issues/407)).
2. Inventory every old Journal under `~/.config/yellowhammer/journals/`, plus the separate absolute
   `[rehearsal] journal` path in each Project file. Archive any diagnostic evidence needed, then delete
   those old Journal databases and their SQLite `-wal` and `-shm` sidecars while all Acts remain stopped.
   Rehearsal Journals live outside the real Journals directory, so clearing that directory alone is
   insufficient. **Never delete `~/.config/yellowhammer/ledger.db` or its sidecars.** Never clear the
   entire config directory: keep configuration, credentials, the Ledger and Repo registrations.
3. The app and engine **refuse an existing older Journal**; the engine does not delete it automatically.
   After explicit deletion, the next Act creates the new Journal. Setup can also create a missing
   Journal during provisioning. Verify the newly created database with
   `sqlite3 -readonly <journal> "SELECT identifier FROM grdb_migrations;"`: it must report
   `journal-schema-24`. The app remains read-only and never creates or migrates a Journal. A Journal
   from a newer build is an upgrade requirement, not a reason to delete it.
4. From the newly installed app's `yh`, run `yh doctor --project <id> --check launchd` for every
   Project. A pre-Phase-23 author plist with only the opening firing is reported as a schedule
   difference when the configured window has periodic firings. Repair each Project with
   `yh doctor --fix --project <id> --check launchd`, or run `yh setup --install-jobs` to regenerate the
   eligible Projects' jobs. Run these only in the maintenance window from step 1, then repeat the
   read-only doctor check and inspect the author plist's `StartCalendarInterval`. Doctor preserves
   paused jobs as unloaded; restore the intended loaded state before leaving the machine unattended.
   Doctor can also repair the machine-wide `/usr/local/bin/yh` link; a scratch-home repair needs the
   [isolation precautions](phase-23-upgrade-verification.md#isolation-for-the-next-live-run).
5. Author now fires at `night_start + offset`, and two minutes after each periodic land tick (one
   minute after build). For a two-minute cadence that delay is one minute; for a one-minute cadence
   it is zero. Keep the Project's existing schedule and let setup/doctor generate the firing grid.
6. `[limits] unmerged_features_max` defaults to **3**. To retain the previous single-Feature-until-merged
   behavior, set it to **1** in each Project file that needs it:

   ```toml
   [limits]
   unmerged_features_max = 1
   ```

   Add the key to an existing `[limits]` table rather than declaring the table twice.

The [Phase 23 verification record](phase-23-upgrade-verification.md) tracks the separate live scratch
checks. Upgrade completion does not establish that the live multi-Feature check passed.

### Release notes upgrade text

Maintain this text locally with the release notes preview; publication follows the
[release checklist](release-checklist.md#15-release-notes-preview-spec-commit-and-story-ids).

> **Upgrading to v0.24.0:** Before the first Act, stop Acts and prevent new firings, then reset every
> older Project Journal, including separately configured rehearsal Journals. Existing older Journals
> are refused; delete them explicitly so the next Act can create `journal-schema-24`. Keep the Ledger.
> While no Act is running, regenerate every Project's LaunchAgents with `yh doctor --fix` or
> `yh setup --install-jobs`, then verify `yh doctor` reports no schedule difference. Author now fires
> periodically, two minutes after land as well as at Night start (short cadences collapse the delay).
> `[limits] unmerged_features_max` defaults to 3; set it to 1 to keep one unmerged Feature at a time.
> See the Phase 23 upgrade runbook for the maintenance sequence and rehearsal Journal paths.
