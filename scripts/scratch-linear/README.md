# Scratch Linear environment (P15.1)

`scratch_linear.py` verifies and cleans up the scratch Linear environment rehearsal Nights run
against. See `../../yellowhammer-spec/docs/tech/system-overview.md` → *Environments* for why
rehearsal exists and what it must never do (never dispatch an agent CLI, never push, never open a
pull request — this tool is unrelated to those three boundaries; it only manages the scratch board).

## The shape

One **scratch Linear team**, shared by every rehearsing Project, lives inside the **scratch
workspace** — the same workspace whose app credential goes into the Keychain per
`../../doc/linear-identity-runbook.md`. Each rehearsing Project has its own **scratch Linear
project** inside that team. Only the scratch workspace's OAuth application's secret ever goes into
`keychain:linear` on a developer machine; production's secret never does.

Worktrees are out of scope here — Orca ADE owns them, and the throwaway Repos a rehearsal Project
points at are P15.2's concern, not this tool's.

## One-time setup

1. Provision the scratch app's credential on the machine, per
   `../../doc/linear-identity-runbook.md` → *Storing credentials* — the **scratch** app's secret,
   never production's:

   First check whether the machine already has it. `-U` overwrites the item, so writing it again is
   how a working secret gets lost:

   ```sh
   security find-generic-password -s dev.yellowhammer -a linear >/dev/null && echo present
   ```

   Only if it is absent (or known to be wrong), store it. Replace the whole placeholder, angle
   brackets included, with the secret itself:

   ```sh
   security add-generic-password -U -s dev.yellowhammer -a linear -w '<scratch-client-secret>'
   ```

   and set `[linear] client_id` in `~/.config/yellowhammer/config.toml` to the scratch app's client
   id.

2. Create the scratch Linear team by hand, in the scratch workspace's Linear UI. This tool and
   `yh setup` both only ever provision *inside* an existing team — neither one ever creates a team.
   Then, in that team:

   - **Add the app user as a team member** (team → Settings → Members, or the app's team access
     in Linear's settings). A `client_credentials` app can *see* every public team but belongs to
     none, and until it is a member Linear refuses its label creation with `FORBIDDEN`. Setup
     currently reports that refusal as "the Project's Linear project is not visible".
   - **Create the three workflow states by hand if setup is refused them:** `Waiting on You`,
     `Kept in Flight` and `Released`, all under **Started**. A same-named state in another
     category (such as `Released` under Completed) is a collision and is never used. Whether team
     membership also lifts this refusal is unconfirmed (yellowhammer-spec#58).
   - A workspace label named `Feature` (one of Linear's defaults) collides with the `Object Type`
     group's `Feature`. Rename or delete it in the scratch workspace.

3. For each rehearsing Project, generate its configuration and provision its Linear project inside
   the scratch team with `yh setup --init` (`Packages/YellowhammerKit/Sources/EngineCommand/
   SetupCommand.swift`, `SetupOptions.swift`). Repos and Spec Source point at throwaway checkouts
   (P15.2); the paths below are placeholders:

   ```sh
   yh setup --init \
     --linear-client-id <scratch-client-id> \
     --cli claude \
     --route claude/sonnet/medium \
     --operator <operator-linear-user-id> \
     --project rehearsal-a \
     --linear-team SCRATCH \
     --spec-source /path/to/throwaway/rehearsal-a-spec \
     --repo 'app,backend,/path/to/throwaway/rehearsal-a-app,swift build'
   ```

   `yh setup --print-choices --linear-client-id <scratch-client-id>` lists the Operator candidates
   and the teams the app can see, and writes nothing.

   This creates the Linear project inside team `SCRATCH` (since `--linear-project` was not given)
   and runs `Engine.BoardProvisioner` for it (workflow states, the `Object Type` and `Block Reason`
   label groups — P5.3). Re-running the same `yh setup --init` keeps the existing Project file
   (so no second Linear project is created) and provisioning reports no changes.

4. Confirm the shape holds:

   ```sh
   python3 scripts/scratch-linear/scratch_linear.py check --team SCRATCH
   ```

## Between rehearsal runs

A rehearsal Night leaves scratch issues and a Journal behind. Reset before the next run:

```sh
python3 scripts/scratch-linear/scratch_linear.py reset --team SCRATCH --project rehearsal-a --dry-run
python3 scripts/scratch-linear/scratch_linear.py reset --team SCRATCH --project rehearsal-a
```

`--project` is required and repeatable — there is deliberately no "reset every Project" default, so
a typo never wipes a Project you did not name.

**What `reset` touches:** it archives every non-archived issue in the named Project's Linear
project (the `issueArchive` mutation — the only mutation this tool ever sends), then deletes that
Project's Journal (`journals/<id>.db`, `-wal`, `-shm`) unless `--keep-journal` is given. An archived
board with a surviving Journal would leave the Outbox and the Delta Read's cursor pointing at issues
that no longer exist, so the Journal goes too by default.

**What it never touches:** provisioning — workflow states, labels, label groups, the Linear project
itself, and the team are never created, renamed, or deleted. It refuses to run at all (exit 2,
nothing changed) if a named Project's Linear project is outside the scratch team, is shared with
another team, or if its Journal's Act lease has not expired (a Night is running).

A second `reset` against an already-clean Project is a no-op and says so.

## Running the unit tests

```sh
python3 -m unittest discover -s scripts/scratch-linear/tests -v
```

Fully offline: a fake HTTP transport records every request, so no test ever calls the real Linear
API or the Keychain. CI (`.github/workflows/scratch-linear.yml`) runs only this; the tool itself
needs the scratch workspace's credentials and network access, which CI does not have.
