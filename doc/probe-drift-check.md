# Scheduled Probe Drift Check and Release Checklist Runbook

P7.5 (`[DevOps]` Scheduled probe drift check; spec R11, ADR-003, `routing/add-an-agent-cli`).

Agent CLIs drift across releases in their argument flags, session resumption handling, output
schemas, and process group / containment behaviors (spec R11). In Yellowhammer, every agent CLI is a
code adapter in `CLIAdapters` paired with a **Probe** that validates unattended execution
contracts and records findings in the machine-wide **Ledger** (`~/.config/yellowhammer/ledger.db`).

The Probe Drift Check verifies that re-running probes detects any regression (drift) between
previously recorded probe results and fresh probe runs, failing loudly before a release ships.

---

## 1. CI Workflows

The drift check is split across two workflows, the same way the rehearsal suite is:

- [`.github/workflows/probe-drift.yml`](../.github/workflows/probe-drift.yml) runs the unit tests
  for the drift runner on a hosted runner, on pull requests and pushes to `main` that touch it:
  `python3 -m unittest discover -s scripts/ci/tests -p 'test_check_probe_drift.py' -v`. It never
  probes.
- [`.github/workflows/probe-drift-live.yml`](../.github/workflows/probe-drift-live.yml) builds the
  app and runs the probes. It is **dormant**: `workflow_dispatch` only, on a self-hosted Apple
  Silicon runner (`[self-hosted, macOS, ARM64]`) that is not registered yet. That runner needs
  `claude` and `codex` installed and authenticated, and a persistent `$HOME` whose Ledger holds the
  earlier Probe Results. A hosted runner has neither, so it cannot probe (#199). The file says
  what to add once the runner exists.

Until then the probe drift check is manual: step 1.2 of
[the release checklist](release-checklist.md#12-probe-drift-check-green).

`scripts/ci/check_probe_drift.py` exits 1 when:

- any probe reports drift (`--no-fail-on-drift` turns this off);
- any probe's verdict is `failed` (`--no-fail-on-error` turns this off);
- any probe did not run at all — no `yh`, a CLI that is not installed, a timeout. Nothing turns
  this off: a probe that never ran is not a green.

---

## 2. Release Checklist Step (P16.7 Runbook)

When preparing a Yellowhammer release, the Operator or Release Engineer must execute the probe drift
verification checklist on an authenticated macOS developer machine or self-hosted runner.

### Step 1: Run Probes Against Pinned CLI Versions

Run the probe drift check across all declared CLI adapters:

```sh
# Via the Yellowhammer engine CLI:
yh probe --all

# Or via the CI orchestration script, which runs the `yh` embedded in the app built with
# `xcodebuild -project Yellowhammer.xcodeproj -scheme Yellowhammer -derivedDataPath .build/app build`
# (pass --engine-bin to use another):
python3 scripts/ci/check_probe_drift.py --clis claude,codex
```

Verify that the output displays findings for each CLI:
- `unattended dispatch`: `passed`
- `result file on clean exit`: `passed`
- `session resumption`: `passed`
- `process containment`: (verified or reported)
- `drift since the previous probe`: `None` (or clean progression)

### Step 2: Test Against Latest Upstream CLI Versions

Check for updated versions of upstream agent CLIs:

```sh
# Check latest Claude Code version
npm view @anthropic-ai/claude-code version

# Update or install latest version in a staging/sandbox prefix
npm install -g @anthropic-ai/claude-code@latest
```

Re-run the probe command against the updated CLI executable:

```sh
yh probe claude
```

### Step 3: Drift Detection and Triage

If the upstream CLI changed its output format, prompt behavior, or flags:

1. `yh probe` detects that a probe target which previously passed is no longer passing.
2. The command reports the regression:
   `drift since the previous probe (<old_version> -> <new_version>): <targets>`
3. The command exits with status code `1` and excludes the CLI from route target eligibility.
4. **Resolution**: Update the corresponding adapter in `Packages/YellowhammerKit/Sources/CLIAdapters/`
   (e.g., updating `CLIOutputSchema`, argv construction, or session resumption options) and verify
   that all tests pass before cutting the release.

---

## 3. How Drift Is Computed in the Ledger

Drift is derived dynamically at read time (`ProbeResult.drift(since:)` in `Ledger/ProbeDrift.swift`)
by comparing the newest `ProbeResult` with the preceding `ProbeResult` stored for the same CLI in
the machine-wide SQLite Ledger (`ledger.db`):

- **Target Regressions Checked**:
  - `unattendedDispatch`: `argv (unattended dispatch)`
  - `resultFileOnCleanExit`: `output format (result file on clean exit)`
  - `sessionResumption`: `session handling (session resumption)`
  - `processContainment`: `process containment`

A regression occurs whenever a target was `.passed` in the previous result but is not `.passed` in
the current result. A clean progression or first-time failure does not trigger drift, while a
breaking upstream change immediately triggers drift and turns the release check red.
