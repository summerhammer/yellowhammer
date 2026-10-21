# Phase 23 upgrade verification — #627

Status: **upgrade setup complete under the narrowed scope of #627**. Operator upgrade instructions
and release-note text are in the [identity runbook](linear-identity-runbook.md#phase-23-upgrade-v0240).
The Operator's doctor-based upgrade setup verification passes for all three existing Projects, as
recorded below. On 2026-10-21, the Operator approved deferring the live multi-Feature checks to
[#636](https://github.com/summerhammer/yellowhammer/issues/636), which will provide repeatable,
automated verification on isolated scratch resources. Those checks are **deferred, not passed**.
The upgrade notice is also published in the
[v0.24.0 release notes](https://github.com/summerhammer/yellowhammer/releases/tag/v0.24.0).

## Downloaded release inspection on 2026-10-21

Published artifact: **v0.24.0, build 763**, release commit `a0383eb0`. At this initial inspection,
the installed app reported v0.22.0; verification used the downloaded release without replacing it.
The subsequent installed-app inspection is recorded below.

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

## Installed app inspection on 2026-10-21

After the Operator installed **v0.24.0, build 763** and removed the old Journals, the installed
inspection was recorded at **19:54 Europe/Kyiv**:

- The installed `yh journal-schema` reports `journal-schema-24`. `codesign --verify` succeeds,
  and `spctl` accepts the app as **Notarized Developer ID**. `/usr/local/bin/yh` resolves to the
  installed app's executable.
- All three configured Projects' production Journal paths are absent; no rehearsal contexts are
  configured. The retained Ledger passes its integrity check. Orca ADE reports ready.
- All nine configured launchd jobs are loaded. No Act PID was present at inspection, and their
  recorded last exit statuses were zero. This does not verify a Night or a scheduled firing.
- Each author plist still contains one firing. Installed doctor expects **28** for `carscalm`,
  **90** for `seshes` and **42** for `yellowhammer`; the production schedules still need repair.
- Doctor reports six failures: each Project lacks adopted mappings for **Waiting on You** and
  **Blocked** after Journal deletion, and the existing Linear states collide with creation.
  The other checks pass, apart from informational retired-taxonomy and `check = "none"` notices.
- Raw local doctor evidence: `.build/issue-627/installed-doctor.json`.

At this inspection the upgrade remained incomplete. The missing state mappings and stale author
schedules were subsequently resolved in the Operator completion below. This inspection covers doctor
and the checks above; it is not a full Night readiness audit, including repository dirtiness and
sleep history.

### Isolated installed-binary plist repair

Using the installed executable and a fresh absolute `CFFIXED_USER_HOME`, a synthetic Project
`issue627-verify` with `22:00`–`06:00` and a five-minute cadence started with one author firing.
Doctor expected 96. `doctor --fix --check launchd --project issue627-verify` regenerated all 96
firings and left the job unloaded; a subsequent read-only doctor reported no schedule difference.
`launchctl print` confirmed that the scratch job was not loaded.

Before/after hashes of production `config.toml`, Project TOMLs and Yellowhammer plists, plus the
CLI symlink target, were unchanged. No scratch Ledger or Journal was created, and no Board call,
Act or job load occurred. Evidence is in `.build/issue-627/installed-scratch-{before,repair,after}.json`
and `.build/issue-627/installed-scratch-summary.json`. This verifies isolated plist repair, not live
scheduling.

At this inspection the remaining production repair commands were `yh doctor --fix --check launchd` and
`yh doctor --fix --check linear`, followed by read-only doctor verification. They were **not run**
against the configured Projects in this inspection; the Linear repair can adopt existing states.

## Operator upgrade setup completion on 2026-10-21

The following evidence is the Operator's terminal output supplied in this session, rather than
another agent-run credential check:

- The Operator regenerated the three production author schedules with `doctor --fix --check launchd`.
  A subsequent check exposed that the CLI symlink targeted a Debug executable in DerivedData,
  while the scheduled jobs targeted `/Applications/Yellowhammer.app/Contents/MacOS/yh` v0.24.0.
  The Debug executable also encountered repeated Keychain prompts; denied requests were reported
  as canceled reads of `linear-summerhammer`.
- The Operator restored the CLI installation through the installed app. Using the installed
  executable's absolute path, `doctor --check launchd` then reported **0 failed, 0 warnings**:
  all nine production jobs were installed and loaded, their executables resolved to the running
  installed binary, and the CLI symlink resolved to it too. This verifies the repaired configuration,
  not an actual scheduled firing.
- Installed `doctor --fix --check linear` adopted the existing **Waiting on You** and **Blocked**
  state identifiers into `[board.linear.mapping]` in each Project TOML: `carscalm` and `seshes`
  use team SUM; `yellowhammer` uses team YLH. The subsequent read-only Linear check reported
  **0 failed, 0 warnings**, with authorization, membership and provisioning passing.
- The full installed `doctor --json` output contained no failures or warnings. Its four
  informational findings were retired taxonomy in the three Projects and `seshes-contracts`
  declaring `check = none` despite having test targets. Configuration, Probes, git, Linear,
  GitHub, Keychain, launchd and Orca ADE checks passed.

The earlier production schedule and state-mapping blockers are resolved. These results establish
doctor-based upgrade setup verification only; they are neither a full Night readiness audit nor
live multi-Feature proof. The supplied commands do not establish that Journals were recreated or
inspect their schemas. No further Journal deletion is required by this verification record.

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

## Live checks deferred to #636

The Operator approved this deferral on 2026-10-21. The live rows below remain unverified under
[#636](https://github.com/summerhammer/yellowhammer/issues/636); closing #627 does not certify them.
Run only after identifying the scratch Linear team/project and resolving the rehearsal limitation.
Retain logs, read-only Journal snapshots, timestamps and the published artifact identity for each row.

| Check | Required evidence | Status |
|---|---|---|
| Two Features in one Night | F1's Verification/landing and archive; next scheduled author at land +2 selects F2; `feature_base` records F1's pinned commit; real Orca Worktree HEAD equals it | Deferred to [#636](https://github.com/summerhammer/yellowhammer/issues/636); ordinary rehearsal cannot make F1's pushed predecessor |
| Stacked PR target | Intended F2 draft targets F1's branch `b1`; rehearsal opens no PR | Deferred to [#636](https://github.com/summerhammer/yellowhammer/issues/636); fixture draft inspection cannot certify live PR creation |
| Limit of one | With `unmerged_features_max = 1`, next author records a quiet skip; Night Card contains “Authoring was skipped: … predecessor Feature … has not merged in …”, merge-commit recommendation and Bounds `\|U\| of 1` | Deferred to [#636](https://github.com/summerhammer/yellowhammer/issues/636) |
| In-flight periodic firing | `actIdle(featureInFlight)` plus unchanged Delta Read counter/log across the firing | Deferred to [#636](https://github.com/summerhammer/yellowhammer/issues/636) |
| Old author plist | Published doctor reports the schedule difference | Passed in isolated inspection above |
| Plist repair | `doctor --fix` regenerates the expected intervals; read-only doctor then reports no schedule difference | Passed in isolated installed-binary check and Operator production verification above; live scheduled firing not tested |
| Observed Merge and pin lifetime | Actual GitHub merge commit; next pass records Observed Merge and removes F1 from U; F1 pin survives while F2 needs it, then disappears when F2's Cycle archives | Deferred to [#636](https://github.com/summerhammer/yellowhammer/issues/636); rehearsal neither pushes nor opens F1's GitHub PR |

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
   The initial downloaded-release inspection therefore did not run `--fix`. In the later
   installed-binary repair check, the existing symlink already targeted that binary and remained
   unchanged. For future repair checks, retain and restore the original CLI link as needed.
5. Archive only the scratch run's evidence, then remove its jobs, Orca Worktrees/registrations and
   scratch Linear objects. Check that the installed CLI link and production configuration remain
   as they were. Update this record and the roadmap's Phase 23 intro with actual outcomes.

The Operator-approved scope change allows #627 to close when #632 merges with the completed
upgrade work and this explicit deferral recorded. [#636](https://github.com/summerhammer/yellowhammer/issues/636)
remains open until the automated live verification and its actual evidence are recorded.
