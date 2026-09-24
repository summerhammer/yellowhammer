# Linear board identity: registration, storage, rotation, revocation

P5.1. Yellowhammer authenticates to Linear as its own registered OAuth 2.0 application, never
as an Operator's personal API key. A personal key silences Linear's self-action notification
suppression, so Yellowhammer's own comments and assignments would never reach the Operator's
Inbox — see spec `system-overview.md` → *Why the board identity is its own subsystem concern*
and the Linear feasibility probe (*Identity & notifications*).

There are two registrations, one per Linear workspace: **scratch** (development) and
**production**. Per the Machine Scope Ruling, a given machine talks to exactly one workspace at a
time — a developer machine points at scratch, a production/CI machine points at production —
so both use the same config reference name, `keychain:linear`; only the Keychain item's contents
differ by machine.

## Registering the app

In the target Linear workspace's OAuth application settings:

1. Create a new application (name: `Yellowhammer`, developer: `Summer Hammer LLC`).
2. Availability: **Private to this workspace** — never a public/listed app.
3. Redirect URI: `http://localhost:8080/callback`. Yellowhammer authenticates with the
   `client_credentials` grant (app-only, no user redirect), so this value is never visited; it
   only satisfies Linear's registration form, which requires one.
4. Copy the **Client ID** and **Client secret**. The secret is shown once (or is only ever
   revealed again on request via "reveal"/"reset"); store it in the Keychain immediately (below).

Repeat once per workspace (scratch, then production) — two separate applications, each scoped to
its own workspace.

## Storing credentials

The client secret never enters the repo or a config file. The machine-wide config file
(`~/.config/yellowhammer/config.toml`) holds the application's client id and only a reference to
the secret:

```toml
[linear]
credential = "keychain:linear"
client_id = "<client-id>"
```

`client_id` is required: the `client_credentials` grant needs it alongside the secret. It is not a
secret — it identifies the registered application, and a scratch machine and a production machine
carry their own workspace's client id. Both keys are machine-wide; a Project file never overrides the
Linear identity.

`Config.KeychainCredentialStore` resolves that reference to the login keychain item
`service = "dev.yellowhammer"`, `account = "linear"`. To provision a machine by hand (until
`yh setup` automates this in P5.3):

```sh
security add-generic-password -U -s dev.yellowhammer -a linear -w '<client-secret>'
```

`-U` updates the item if one already exists for that service/account, which is what rotation
(below) uses. Do this once per machine:

- **Developer machines and CI** (GitHub Actions macOS runners, for adapter tests against the
  scratch workspace — from P5.2 onward) get the **scratch** app's secret. CI has no persistent
  Keychain across runs, so a workflow step provisions it at job start from a `LINEAR_SCRATCH_CLIENT_SECRET`
  repository secret, using the command above against the runner's already-unlocked default
  keychain. No such workflow step exists yet: P5.2's adapter tests are hermetic, and the one live
  test (below) is opt-in, so CI does not need the secret until a live test runs there.
- **The Operator's real daily-use machine** — wherever Yellowhammer actually manages real
  Projects, as opposed to a throwaway dev/test run — gets the **production** app's secret. This
  is not a hosted service; "production" here means "the machine actually doing the work," which
  may be the same physical Mac as a developer machine at different times, never both credentials
  in the Keychain simultaneously (a machine has exactly one workspace at a time, per `keychain:linear`).

## Verifying a token can be obtained

Confirm the `client_credentials` grant works against each workspace before considering this done:

```sh
curl -s https://api.linear.app/oauth/token \
  -d client_id=<client-id> \
  -d client_secret=<client-secret> \
  -d grant_type=client_credentials \
  -d scope=read,write
```

`scope` is required for the `client_credentials` grant — omitting it fails with `invalid_scope`. A
`client_credentials` token is inherently an app-actor token (no separate `actor=app` parameter on
this endpoint; that parameter belongs to the authorization-code install flow, not this grant). The
resulting token has access to all public teams in the workspace and is valid for 30 days.

A successful response returns an access token. Post one comment on a test issue with it and
confirm the comment triggers an Inbox notification (`issueNewComment`) for the Operator — the
concrete acceptance check for this story.

## Running the live adapter test

The Linear adapter's tests run offline against a stub transport. One test, `LinearScratchTests`,
talks to the real **scratch** workspace: it obtains a token, checks that `viewer` resolves to the
registered application rather than an Operator, and reads one page of the scratch Linear project's
issues. It is opt-in and skips cleanly when its inputs are absent:

```sh
YH_LINEAR_SCRATCH_TESTS=1 \
YH_LINEAR_CLIENT_ID=<scratch-client-id> \
YH_LINEAR_PROJECT_ID=<scratch-linear-project-id> \
swift test --package-path Packages/YellowhammerKit --filter LinearScratchTests
```

The client secret is read from the `keychain:linear` item provisioned above, never from the
environment. Run it on a developer machine holding the scratch secret, never on one holding production's.

## Rotation

1. In the Linear workspace's OAuth application settings, reset the client secret. The client ID
   does not change, so `client_id` in `config.toml` stays as it is.
2. Update every machine's Keychain item for that workspace with the new secret:
   `security add-generic-password -U -s dev.yellowhammer -a linear -w '<new-client-secret>'`.
3. Re-run the verification `curl` above against the workspace to confirm the new secret works
   before removing any old copy of it.
4. Rotate scratch and production independently; rotating one never requires touching the other.

Rotate on a credential-compromise suspicion, on developer-machine offboarding, and otherwise on
whatever cadence the Operator sets — the spec does not mandate a schedule.

## Revocation

1. In the Linear workspace's OAuth application settings, delete the application (or reset its
   secret and discard the new one without distributing it, if the app must keep functioning for a
   grace period at first).
2. Remove the Keychain item from every machine that held it:
   `security delete-generic-password -s dev.yellowhammer -a linear`. If the application was deleted,
   its `client_id` in `config.toml` is dead too; replace it when a new application is registered.
3. Deleting the application immediately invalidates every token issued under it — no separate
   token-revocation step is needed for the `client_credentials` grant.

## Provisioning (P5.3)

`Engine.BoardProvisioner` provisions what the board projection depends on. It is run by setup
(`yh setup`, P13.1) through `EngineCommand.BoardBinding.provisioning`. It only ever **creates**: it
never renames, moves, re-parents, archives or deletes anything already on the board.

For the Project's Linear project it verifies the Linear project exists. When it does not, it is
created only if setup names a team to create it in; otherwise it is reported `missing` and nothing
else is touched. The new Linear project's id must then be written to `linear_project`.

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
YH_LINEAR_CLIENT_ID=<scratch-client-id> \
YH_LINEAR_PROJECT_ID=<scratch-linear-project-id> \
swift test --package-path Packages/YellowhammerKit --filter BoardProvisionerScratchTests
```

## Scratch environment (P15.1)

Between rehearsal Night runs, the scratch Linear team's issues need archiving and each rehearsing
Project's Journal needs clearing, without touching provisioning. See
`../scripts/scratch-linear/README.md` for the runbook and `scripts/scratch-linear/scratch_linear.py`
for the `check`/`reset` tool.
