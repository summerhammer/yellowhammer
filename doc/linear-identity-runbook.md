# Linear board identity: App Installations, storage, re-connecting, removal

Yellowhammer authenticates to Linear as its own app user, through an **App Installation** of its
Linear OAuth application in a Linear workspace — never as an Operator's personal API key. A personal
key silences Linear's self-action notification suppression, so Yellowhammer's own comments and
assignments would never reach the Operator's Inbox — see spec `system-overview.md` → *Why the board
identity is its own subsystem concern* and the Linear feasibility probe (*Identity & notifications*).

The machine holds a registry of App Installations, zero or more, one per Linear workspace. Each
Project selects one by name. A developer Mac can hold a scratch installation and a production
installation at once; nothing is shared between them (see *Storage*). The earlier rule that a machine
talks to exactly one workspace, through a single `keychain:linear` reference, is gone, and so is the
`client_credentials` / `client_id` identity it went with.

## Connecting a workspace

```sh
yh setup --install-linear
```

This opens the browser for a Linear workspace admin to approve the app. There is no client id and no
client secret to copy. The approval creates the app user in that workspace; Yellowhammer then
stores the token pair and registers the installation (below).

- Re-connecting a workspace that is already registered replaces its tokens and keeps its local name
  and its Operator identity. `yh setup --install-linear --installation <name>` re-connects that one
  installation.
- The local `<name>` defaults to the workspace URL key and is fixed once written. Name it yourself
  with `yh setup --install-linear --installation-name <name>` (the app's name field passes the same
  flag). An invalid name, or one another installation uses, is refused before the browser opens. If
  Linear approves a workspace that is already connected, that installation is re-connected and the
  given name is discarded.
- Two entries with one workspace are refused.
- Choose which Linear teams the app user joins on the install screen. The app user must be a
  **member** of the team a Project provisions inside; "All public teams" does not make it one (see
  `../scripts/scratch-linear/README.md`).

## Storage

The machine-wide config file (`~/.config/yellowhammer/config.toml`) holds zero or more installations:

```toml
[board.linear.installations.<name>]
credential = "keychain:linear-<name>"
workspace = "<Linear workspace id>"
app_user = "<app user id>"
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
installation = "<name>"
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
yh setup --print-choices [--installation <name>]
yh config operator --installation <name> <user-id>
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

`YH_LINEAR_INSTALLATION` names the scratch App Installation; the test reads its token pair from the
Keychain item `linear-<name>` and writes refreshed pairs back. There is no client id or secret in the
environment. Run it on a developer machine holding the scratch installation, never against production's.

## Re-connecting (token rotation)

The engine refreshes the token pair itself under the installation's refresh lock. Re-connect when that
no longer works (the doctor reports the installation's authorization as failing), on a compromise
suspicion, or on developer-machine offboarding:

1. `yh setup --install-linear --installation <name>`, and approve in Linear again. The tokens in that
   installation's Keychain item are replaced; its name and Operator identity are kept.
2. `yh doctor --check linear` to confirm the installation is healthy.
3. Installations are independent: re-connecting one never touches another.

The spec does not mandate a schedule.

## Removal and revocation

```sh
yh config remove-installation <name>
```

This is refused while any Project names the installation. Otherwise it deletes the entry from
`config.toml` and its Keychain item. The app stays installed in Linear; revoking it there is a
workspace admin's action in Linear's settings.

When the installation's authorization can never be restored (the workspace was deleted, or no admin
will approve again) and a Project still names it, `yh project remove` cannot finish while a Feature
is in flight. The exit is:

```sh
yh config remove-installation <name> --orphan-projects   # asks to confirm; --yes skips the prompt
```

It removes the entry and its Keychain item even while Projects name it, but only when a live check
finds the authorization refused. An absent Keychain item counts as refused. An unreadable Keychain
item or an unreachable Linear refuses it and exits 1. It is still refused while a Project file fails
to decode. Then run `yh project remove <id>` for each Project it lists: the release comment is
skipped and reported. To undo, re-connect the same workspace with
`yh setup --installation-name <name>` under the exact same local name. Do not delete a Project file
by hand: that skips the WIP Commit and push. Settings offers the same as **Remove Anyway…**.

## Provisioning (P5.3)

`Engine.BoardProvisioner` provisions what the board projection depends on. It is run by setup
(`yh setup`, P13.1) through `EngineCommand.BoardBinding.provisioning`. It only ever **creates**: it
never renames, moves, re-parents, archives or deletes anything already on the board.

For the Project's Linear project it verifies the Linear project exists. When it does not, it is
created only if setup names a team to create it in; otherwise it is reported `missing` and nothing
else is touched. The new Linear project's id must then be written to `[board.linear] project`.

Then, **once per team** the Linear project belongs to (Projects sharing a team share the result):

- the `Waiting on You`, `Blocked`, `Kept in Flight` and `Released` workflow states (type
  `started`), each matched by name, case-insensitively;
- the label group `Object Type` with `Feature`, `Card`, `Night Card`;
- the label group `Block Reason` with `blocked by reviewer`, `blocked by check`, `hard failure`,
  `host crash`, `unanswered`, `undecided`, `released` (`BlockReason.allCases`).

Every item is reported `present`, `created`, `collision` or `blocked`. A label of the same name
anywhere the team can see it — a workspace label, a team label, or a label in another group — is a
**collision**: reported, never overwritten, and that one label is not created. (The feasibility
probe's workspace already had a workspace-level `Feature`.) A non-group label holding a group's name
blocks the whole group. A workflow state's uniqueness is scoped to (name, type), not name alone (a
live probe found a team-owned `Released` of type `completed` coexisting with ours of type `started`):
a same-named workflow state of a different type — including one this build cannot categorize — is
also a **collision**, reported and never reused. Resolve a collision by hand in Linear, then run
provisioning again.

The three Override label groups (gate G-17, P7.6) are provisioned only when setup is given a
Routing Table; see `BoardProvisioner.provision(routingTable:)`.

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
