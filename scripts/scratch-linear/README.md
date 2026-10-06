# Scratch Linear environment (P15.1)

`scratch_linear.py` verifies and cleans up the scratch Linear environment rehearsal Nights run
against. See `../../yellowhammer-spec/docs/tech/system-overview.md` → *Environments* for why
rehearsal exists and what it must never do (never dispatch an agent CLI, never push, never open a
pull request — this tool is unrelated to those three boundaries; it only manages the scratch board).

## The shape

One **scratch Linear team**, shared by every rehearsing Project, lives inside the **scratch
workspace** — the same workspace Yellowhammer's App Installation (P17.3–P17.7) is installed into on
this machine, whose token pair the Keychain holds (item `linear-<name>`). Each rehearsing Project has
its own **scratch Linear project** inside that team. A machine may hold several installations at once;
every script here acts through one of them, picked by `--installation NAME` (default: the sole
installation; none, or several without the flag, is refused). The scratch tools only ever touch the
installation they are given, so name the scratch one on a Mac that also holds production's.

Worktrees are out of scope here — Orca ADE owns them, and the throwaway Repos a rehearsal Project
points at are P15.2's concern, not this tool's.

## One-time setup

1. Install Yellowhammer's Linear app into the scratch workspace: `yh setup --install-linear`. This
   opens the browser for a workspace admin to approve — no client id, no secret, ever (the
   `client_credentials` identity this tool used before P17.6 is withdrawn). Re-connecting a registered
   workspace replaces its tokens and keeps its name and Operator identity
   (`yh setup --install-linear --installation <name>`). On the install screen,
   choose **"Only select teams… → SCRATCH"** (the scratch team) rather than the preselected "All
   public teams" — only the former makes the app user a **member** of the team, which the
   label/workflow creates below need. The tokens land in the Keychain (service `dev.yellowhammer`, account `linear-<name>`) and
   `~/.config/yellowhammer/config.toml` gets a `[board.linear.installations.<name>]` table with
   `credential`, `workspace` and `app_user`; `<name>` defaults to the workspace URL key. `yh doctor
   --check linear --json` confirms it afterwards.

2. In the scratch team (already created by hand in Linear's UI — this tool and `yh setup` both only
   ever provision *inside* an existing team, neither one ever creates one):

   - Confirm the app user is a team member (team → Settings → Members). Choosing "Only select
     teams… → SCRATCH" at install does this already; "All public teams" would not, and Linear then
     refuses label creation with `FORBIDDEN` — setup reports that as "the Project's Linear project
     is not visible".
   - **Create the four workflow states by hand if setup is refused them:** `Waiting on You`,
     `Blocked`, `Kept in Flight` and `Released`, all under **Started**. A same-named state in
     another category (such as `Released` under Completed) is a collision and is never used.
     Whether team membership also lifts this refusal is unconfirmed (yellowhammer-spec#58).
   - The `Card Type` group provisions `Feature Card`, `Work Card`, and `Night Card`, none of
     which collides with Linear's default `Feature` workspace label (OQ125).

3. For each rehearsing Project, generate its configuration and provision its Linear project inside
   the scratch team with `yh setup --init --installation <name>` (`Packages/YellowhammerKit/Sources/EngineCommand/
   SetupCommand.swift`, `SetupOptions.swift`). Repos and Spec Source point at throwaway checkouts
   (P15.2); the paths below are placeholders:

   ```sh
   yh setup --init \
     --installation <scratch-installation-name> \
     --cli claude \
     --route claude/sonnet/medium \
     --operator <operator-linear-user-id> \
     --project rehearsal-a \
     --linear-team SCRATCH \
     --spec-source /path/to/throwaway/rehearsal-a-spec \
     --repo 'app,backend,/path/to/throwaway/rehearsal-a-app,swift build'
   ```

   `yh setup --print-choices [--installation <name>]` lists the Operator candidates and the teams the app can see, and
   writes nothing.

   This writes `[board.linear]` with `installation` and `project` in the Project file, and creates the
   Linear project inside team `SCRATCH` (since `--linear-project` was not given)
   and runs `Engine.BoardProvisioner` for it (workflow states, the `Card Type` and `Block Reason`
   label groups — P5.3). Re-running the same `yh setup --init` keeps the existing Project file
   (so no second Linear project is created) and provisioning reports no changes.

4. Confirm the shape holds:

   ```sh
   python3 scripts/scratch-linear/scratch_linear.py [--installation NAME] check --team SCRATCH
   ```

## Between rehearsal runs

A rehearsal Night leaves scratch issues and a Journal behind. Reset before the next run:

```sh
python3 scripts/scratch-linear/scratch_linear.py [--installation NAME] reset --team SCRATCH --project rehearsal-a --dry-run
python3 scripts/scratch-linear/scratch_linear.py [--installation NAME] reset --team SCRATCH --project rehearsal-a
```

`--installation` is a global flag, given before the subcommand. `--project` is required and repeatable — there is deliberately no "reset every Project" default, so
a typo never wipes a Project you did not name.

**What `reset` touches:** it archives every non-archived issue in the named Project's Linear
project (the `issueArchive` mutation — the only mutation this tool ever sends), then deletes that
Project's Journal (`journals/<id>.db`, `-wal`, `-shm`) unless `--keep-journal` is given. An archived
board with a surviving Journal would leave the Outbox and the Delta Read's cursor pointing at issues
that no longer exist, so the Journal goes too by default.

**What it never touches:** provisioning — workflow states, labels, label groups, the Linear project
itself, and the team are never created, renamed, or deleted. It refuses to run at all (exit 2,
nothing changed) if a named Project's `[board.linear] installation` is a different installation, if its
Linear project is outside the scratch team, is shared with
another team, or if its Journal's Act lease has not expired (a Night is running).

A second `reset` against an already-clean Project is a no-op and says so.

## Running the unit tests

```sh
python3 -m unittest discover -s scripts/scratch-linear/tests -v
```

Fully offline: a fake HTTP transport records every request, so no test ever calls the real Linear
API or the Keychain. CI (`.github/workflows/scratch-linear.yml`) runs only this; the tool itself
needs the scratch workspace's credentials and network access, which CI does not have.
