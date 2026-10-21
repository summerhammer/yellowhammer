# Phase 23 upgrade verification — #627

Status: **partial; live multi-Feature verification remains pending**. Operator upgrade instructions
and release-note text are in the [identity runbook](linear-identity-runbook.md#phase-23-upgrade-v0240).
This record does not certify that existing Projects have been upgraded.

## Recorded on 2026-10-21

Published artifact: **v0.24.0, build 763**, release commit `a0383eb0`. The installed app reports
v0.22.0; verification used the downloaded release without replacing it.

- The ZIP's SHA-256 matched the published `SHA256SUMS`:
  `f38ef030e84ec9d06890b4a484821a258d1b2916ccba758026d00ca5951705a7`.
- The downloaded `yh journal-schema` returned `{"schema":"journal-schema-24"}`.
- Orca ADE reported `runtimeState: ready`, `runtimeReachable: true`, `graphState: ready`.
- With `CFFIXED_USER_HOME` set to an absolute temporary home, a synthetic scratch Project configured
  with `22:00`–`06:00`, `build_every_minutes = 5`, and the sole Project's offset zero was read by
  the published `yh doctor --check launchd --project issue627 --json`. A scratch author plist held
  only `22:00`, pointed at the downloaded executable, and was never loaded into launchd.
  Doctor reported **“1 installed firings, 96 implied by [schedule]”** and recommended `yh doctor --fix`.
  This confirms detection against the published binary; it does not verify a scheduled firing.
- Raw local evidence is under `.build/issue-627/`: `SHA256SUMS`, `doctor-old-author.json`,
  `doctor-old-author.stderr`, the extracted release, and `home/` containing the scratch config/plist.
  Doctor created no scratch Ledger. No Act, board mutation, job load, Journal reset or repair was run.

The scratch configuration used placeholder Board/Code Hosting references: this doctor check makes
no credential request. The configured `summerhammer` Board Connection has not been established as
the intended scratch target, and no scratch team/project was supplied for this run.

## Why the full requested rehearsal cannot yet pass

A normal rehearsal cannot produce the predecessor required by #627's successor-selection check:

- `LandAct+LaneSteps.swift` returns a rehearsal boundary before push and `recordLandedTip`.
- `LandAct+FeatureSteps.swift` leaves a Cycle unarchived when `pushedRepositories` is empty, even
  with a fixture Verification verdict. Thus F1 remains in flight and no real landed pin is produced.
- The existing `EngineCommandTests/MultiFeatureNightTests.swift` uses seeded authoring rows, a stub
  Workspace and Publication, and real-mode local fixture pushes. It supplies deterministic coverage,
  not a live rehearsal with Orca ADE and GitHub.

Keep the rehearsal boundaries. Do not seed a successful push, archive or Observed Merge into a live
Journal and report it as an observed result. Completing the requested flow needs a revised check
that separates seeded fixture coverage from live observations, or an explicitly scoped real-mode
scratch run with actual publication. Neither is silently substituted for rehearsal here.

## Remaining checks

Run only after identifying the scratch Linear team/project and resolving the rehearsal limitation.
Retain logs, read-only Journal snapshots, timestamps and the published artifact identity for each row.

| Check | Required evidence | Status |
|---|---|---|
| Two Features in one Night | F1's Verification/landing and archive; next scheduled author at land +2 selects F2; `feature_base` records F1's pinned commit; real Orca Worktree HEAD equals it | Pending; ordinary rehearsal cannot make F1's pushed predecessor |
| Stacked PR target | Intended F2 draft targets F1's branch `b1`; rehearsal opens no PR | Pending; fixture draft inspection cannot certify live PR creation |
| Limit of one | With `unmerged_features_max = 1`, next author records a quiet skip; Night Card contains “Authoring was skipped: … predecessor Feature … has not merged in …”, merge-commit recommendation and Bounds `\|U\| of 1` | Pending |
| In-flight periodic firing | `actIdle(featureInFlight)` plus unchanged Delta Read counter/log across the firing | Pending |
| Old author plist | Published doctor reports the schedule difference | Passed in isolated inspection above |
| Plist repair | `doctor --fix` regenerates the expected intervals; read-only doctor then reports no schedule difference | Pending; see machine-wide symlink side effect below |
| Observed Merge and pin lifetime | Actual GitHub merge commit; next pass records Observed Merge and removes F1 from U; F1 pin survives while F2 needs it, then disappears when F2's Cycle archives | Pending; rehearsal neither pushes nor opens F1's GitHub PR |

## Isolation for the next live run

1. Use the published artifact. Make a new absolute scratch home with `mktemp -d`, then set
   `CFFIXED_USER_HOME` to it for **every** `yh` invocation. Put only scratch configuration in
   `$CFFIXED_USER_HOME/.config/yellowhammer/`. The Ledger must be newly created there; never copy,
   migrate or reset the production Ledger. Establish any required Probe Result in that scratch
   Ledger as a separately attended step.
2. Python's `Path.home()` does not follow `CFFIXED_USER_HOME`. If invoking the existing rehearsal
   tooling, also pass `--configuration-directory "$CFFIXED_USER_HOME/.config/yellowhammer"`, a
   scratch `--root` and work directory explicitly. This prevents Python from using real config
   while the child `yh` uses the scratch home.
3. Explicitly configure the scratch Board Connection, Code Hosting Connection, Project and
   `[rehearsal]` context. Its absolute Journal path must also be under the scratch home, with the
   confirmed scratch Linear project as its target. Point every Repo and Spec Source at throwaway
   checkouts. Verify all resolved paths before running any Act. Do not install scheduled jobs for
   real Projects or run the suite's default configuration from the real home.
4. Keep any inspected plists unloaded until a scheduled test is deliberately ready. Before repair,
   stop all scratch Acts. **`CFFIXED_USER_HOME` does not isolate `/usr/local/bin/yh`: doctor
   `--fix --check launchd` can repoint that machine-wide symlink**, even without `--repoint`.
   The isolated inspection above therefore did not run `--fix`. Plan that side effect explicitly
   for an attended repair check; retain and restore the original CLI link before concluding it.
5. Archive only the scratch run's evidence, then remove its jobs, Orca Worktrees/registrations and
   scratch Linear objects. Check that the installed CLI link and production configuration remain
   as they were. Update this record and the roadmap's Phase 23 intro with actual outcomes.

Keep #627 open until all required live results are recorded. A documentation PR does not close it.
