---
name: investigate-night-readiness
description: Audit whether the installed Yellowhammer app and every configured Project (or one named Project) are ready for an unattended Night, and report a READY / WARNING / BLOCKED verdict with exact remediation commands. Use when the Operator asks if a Night will run, before leaving a Mac for the night, after an upgrade, or when diagnosing a missed Night. Strictly read-only.
---

# Investigate Night readiness

A deterministic, read-only audit of the *installed* product — `/Applications/Yellowhammer.app`, the
`yh` CLI, `launchd`, power, Keychain, the Ledger, each Project's Journal, Linear, git, GitHub and
Orca ADE — answering one question: will the Night fire, and finish, with nobody there?

Argument: optional `project` (a Project id, e.g. `seshes`). Absent, audit every configured Project.
Present, audit that Project plus the machine-wide checks, and nothing about its siblings (no
cross-Project verdict: ADR-002).

## Hard rules

- **Read-only.** Never run `yh doctor --fix` (with or without `--repoint`/`--yes`), `yh doctor --probe`,
  `yh probe`, `yh setup`, `yh act`, `launchctl load|unload|bootstrap|bootout|kickstart|enable|disable`,
  `pmset` with a setting, `git` writes, or anything that opens a Journal or the Ledger for writing.
  `yh probe` spawns an agent CLI and writes the Ledger, and a Keychain dialog it raises survives the
  client being killed — an audit must never cause the failure it looks for. Print fixes as text for
  the Operator.
- **Never read secrets.** No `security find-generic-password -w`, `-g`, `dump-keychain`. The `keychain`
  check of `yh doctor` reads attributes only; use it.
- **Use the installed `yh` on `$PATH` against the real config dir** — this is a check of what will run
  tonight. Do not build or run a branch `yh` here (it can migrate the live Ledger).
- No filesystem searches outside the paths named below. Never `find ~`.
- Run commands with absolute paths and `git -C`; no `cd &&` chains, no `|| echo` fallbacks.
- Read SQLite files only with `sqlite3 -readonly`, and copy nothing out of them beyond the columns named.

## Check sequence

Run in this order. Record every result as a finding: `{id, severity pass|warn|fail|info, evidence, fix}`.
A command that cannot run is itself a finding (`warn` if the check is advisory, `fail` if it gates the Night).

### A. Machine-wide

| id | Check | How | fail / warn when |
|---|---|---|---|
| A1 | App installed | `ls -d /Applications/Yellowhammer.app`; version: `defaults read /Applications/Yellowhammer.app/Contents/Info CFBundleShortVersionString` | fail: missing |
| A2 | Signed + notarized | `codesign --verify --deep --strict /Applications/Yellowhammer.app`; `codesign -dv --verbose=2 …` (Authority must be `Developer ID Application`); `spctl --assess --type execute -v …` | fail: verify fails or spctl rejects; warn: ad-hoc/Development signature |
| A3 | `yh` link | `ls -l /usr/local/bin/yh`; `yh --version` (or `/Applications/Yellowhammer.app/Contents/MacOS/yh --version`) | fail: missing or dangling; warn: version differs from the app's (`yh doctor --fix` would repoint) |
| A4 | Machine config | `ls ~/.config/yellowhammer/config.toml`, `ls ~/.config/yellowhammer/projects/` | fail: no config or no Projects |
| A5 | Doctor (machine) | `yh doctor --json` (all checks; add `--project <id>` when scoped) — parse the JSON array | see "Doctor mapping" |
| A6 | LaunchAgents | `ls ~/Library/LaunchAgents/dev.yellowhammer.*.plist`; `launchctl list` filtered to `dev.yellowhammer`; `launchctl print-disabled gui/$(id -u)` filtered to `dev.yellowhammer`. Expect `author`, `build`, `land` per Project, labelled `dev.yellowhammer.<project>.<act>` | fail: a Project has no installed job; warn: installed but not loaded, `"…" => disabled`, or non-zero last exit status |
| A7 | Schedule alignment | Doctor's `launchd` findings (A5) compare each plist's firings to `[schedule]`; also read the plists' `StartCalendarInterval` and confirm they fall in the Night window | warn: stale vs `[schedule]` |
| A8 | Power | `pmset -g`, `pmset -g assertions`, `pmset -g sched`. Machine must stay awake through the Night window: no `sleep` timer shorter than the window unless a `PreventSystemSleep`/caffeinate-style assertion or scheduled wake covers it. Laptop lid/clamshell and battery-only are risks | fail: system sleep enabled with no wake coverage of the window; warn: display-only coverage, battery power, `powernap` off |
| A9 | Sleep/wake history | `yh status` (per-Project sleep history and missed-Night diagnosis) and `pmset -g log` tail for `Sleep`/`Wake` during recent Night windows | warn: a recent Night overlapped a sleep interval |
| A10 | Keychain ACLs | Doctor `keychain` findings (A5): *Always Allow* widened an item (`security` in the access list, `apple-tool:` in the partition list — issues #546, #554, #573) | fail: widened; warn: unreadable |
| A11 | Ledger | `sqlite3 -readonly ~/.config/yellowhammer/ledger.db "PRAGMA integrity_check;"`; `ls ~/.config/yellowhammer/ledger.db.lock` is informational | fail: not `ok` or unopenable |
| A12 | Agent CLIs installed | for each CLI Adapter declared in `config.toml` (`claude`, `codex`, `agy`, …): `command -v <cli>` and `<cli> --version`; also confirm the launchd `PATH` can see it — the plist's `EnvironmentVariables.PATH` (via `plutil -p`) includes the CLI's directory (a missing pnpm/node dir has failed Nights) | fail: a declared CLI is absent from the job PATH |

### B. Per Project

For each Project in scope (`ls ~/.config/yellowhammer/projects/*.toml`; Project id = file stem):

| id | Check | How | fail / warn when |
|---|---|---|---|
| B1 | Config + Bounds | Doctor `configuration` findings for the Project; read `projects/<id>.toml`: `[schedule]` and `[limits]` present and sane (`pass_timeout_minutes` > 0, night window non-empty) | fail: invalid; warn: defaults relied on |
| B2 | Journal present + schema | `ls ~/.config/yellowhammer/journals/`; Journal file for the Project; `sqlite3 -readonly <journal> "PRAGMA integrity_check;"`. A Journal older or newer than the installed build is refused by both app and engine — compare the schema identifier the installed app expects (read `yh doctor` message, or the Journal's migrations table `SELECT identifier FROM grdb_migrations;` against the installed version's release notes) | fail: unopenable or schema mismatch (fix: Journal is deleted and recreated by the engine for older pre-1.0 builds — tell the Operator, do not do it) |
| B3 | Stale leases | `sqlite3 -readonly <journal> "SELECT act, run_id, mode, claimed_at, heartbeat_at, expires_at FROM act_lease;"` (empty means no live lease); compare to `date -u`. Lease TTL is 10 min, heartbeat 60 s | fail: a lease with `expires_at` in the past and no live `yh` process (`pgrep -fl 'yh '`) — it will be reclaimed, but report it; warn: a live lease right now (a Night is running or a process is wedged) |
| B4 | Board (Linear) | Doctor `linear` findings: authorization valid, required statuses and labels (incl. `authoring defect` and every Block Reason label) provisioned, Operator identity set, board membership | fail: unauthorized or missing label (fix: `yh doctor --fix --check linear`; after an upgrade, `yh setup --config ~/.config/yellowhammer`) |
| B5 | Git | Doctor `git` findings: git ≥ 2.38, every Repo path and spec source is a work tree. Additionally `git -C <repo> status --porcelain` and `git -C <repo> branch --show-current` per Repo | fail: path not a work tree; warn: uncommitted changes in a working Repo, or detached HEAD |
| B6 | Code hosting | Doctor `github` findings: the credential resolves and can push to every working Repo | fail: cannot push |
| B7 | Workspace (Orca ADE) | Doctor `orca` findings: every Repo registered (fix: `orca repo add <path>`) | fail: unregistered |
| B8 | Routes / Probe Results | Doctor `probes` findings read the **recorded** Probe Result from the Ledger. Additionally list the Project's declared routes from its toml and confirm each routed CLI is `offered`; read last probe time: `sqlite3 -readonly ~/.config/yellowhammer/ledger.db "SELECT cli, probed_at, verdict, cli_version FROM probe_result ORDER BY probed_at DESC;"` | fail: a routed CLI is excluded or never probed; warn: the recorded `cli_version` differs from the installed CLI's `--version` (probe drift: `doc/probe-drift-check.md`) |
| B9 | Verification route | The Project declares a Verification fallback route (live Nights have been blocked without one) | warn: absent |

### Doctor mapping

`yh doctor --json` prints one array of `{check, subject, severity, message, projects?, …}` where `check`
is one of `configuration, probes, git, linear, github, keychain, launchd, orphans, orca` and `severity`
is `pass|warning|failure|info`. Map `failure → fail`, `warning → warn`, keep `pass`/`info`. Exit status 1
means at least one failure. Run once for everything (A5), then **attribute** findings by `projects`/`subject`
to B-checks. `--check <name>` narrows to one check if a rerun is needed. Doctor's own `message` usually
carries the fix; copy it verbatim as the finding's `fix`.

## Verdict

- **BLOCKED** — any `fail`. The Night will not run, or will run and fail. State which Acts/Projects.
- **WARNING** — no `fail`, at least one `warn`. The Night should run; list what could degrade it.
- **READY** — no `fail`, no `warn`.

Scoped to a Project, the verdict is that Project's alone (plus machine-wide findings). Without a
scope, give one verdict **per Project** and a machine-wide verdict; never blend Projects' data into
one number. The overall line is the worst of them, stated as "worst of N".

## Output

1. A header: audited at (local time + zone), `yh` and app versions, scope, next Night start per
   `[schedule]`.
2. A `READY | WARNING | BLOCKED` line.
3. A findings table for non-pass findings, worst first: id, severity, what, evidence (command + the
   relevant line), **exact remediation command**.
4. A short list of passes (ids only) so the Operator can see what was covered, and of any check
   **skipped**, with the reason. Never report a check as passed that did not run.
5. A fenced JSON block for machines:

```json
{"verdict":"WARNING","scope":"all","machine":{"verdict":"READY"},
 "projects":{"seshes":{"verdict":"WARNING"}},
 "findings":[{"id":"A8","severity":"warn","evidence":"…","fix":"…"}]}
```

Remediations are printed, never run. Common ones: `yh doctor --fix` (regenerate jobs, symlink),
`yh doctor --fix --check linear`, `yh setup --install-jobs`, `yh probe <cli>` (the Operator runs it,
attended, never during a Night), `orca repo add <path>`, `yh config replace-code-hosting-token <name> --token-stdin`,
delete the widened Keychain item then `yh setup --install-linear`, `sudo pmset -c sleep 0`
(or schedule a wake with `sudo pmset repeat wakeorpoweron …`).

## Pitfalls

- A rehearsal Night is a runtime mode, not a readiness proof; this audit does not substitute for it.
- Do not treat a passing doctor as READY: it does not cover power, Keychain-vs-prompt history, job
  PATH, or the lease state.
- Do not widen scope when `project` is given: no sibling Project's findings, not even "while here".
- Keychain prompts are unattended-Night killers: on any prompt-related finding, advise the Operator to
  answer **Deny** to a pass's dialog.
