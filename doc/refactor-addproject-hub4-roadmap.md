# Refactor Add Project to Hub4 — roadmap

This roadmap rebuilds the Add Project sheet (P18.17, `Features/AddProject`) in the Hub4 layout.
Hub4 was chosen in `Packages/Prototypes/Sources/AddProjectPrototypes` (commit `fad8b2d`). It is a
separate roadmap from `implementation-roadmap.md`, which it does not renumber. When H3 is done,
`implementation-roadmap.md` gets one line linking here.

**Spec** — `app/add-a-project-via-the-setup-wizard`. Read it and the `app` epic's `overview.md`
before each step. The story sets no step order, so the hub needs no ruling.

## What changes, and what is already there

- **Steps.** Hub4's steps are Project & Linear project, Repos, Spec Source, Bounds and Scheduled
  jobs, in a hub that marks each step done, problem or current. It asks for confirmation before
  the Project id becomes permanent. `SetupInvocation.Project` already carries the Linear project,
  `specSource` and `repos`, so those steps need no Engine work.
- **Bounds go to the config file.** `yh setup` takes no Bounds. Settings → Recalibrate edits them
  through `ProjectConfigurationModel.save()` (P14.3's path), which writes the Project file. The
  wizard uses that same path, *after* `yh setup --init` has written the Project file and only if
  it succeeded. Bounds left at their defaults are not written. If the Bounds write is refused, the
  Project still exists with default Bounds. The sheet shows the refusal as
  `ProjectConfigurationModel.failure` reports it, says Bounds can be changed in Settings →
  Recalibrate, and does not roll the Project back. Cancel before the run still leaves nothing
  behind.
- **The machine-wide steps leave the sheet.** The spec puts Linear auth, Operator identity and
  agent CLIs / routing defaults in Settings → General. The sheet no longer has steps for them.
  A first Project on a fresh Mac still needs them, so the sheet checks each one (the Linear
  installation through `yh doctor`, as the sheet does today) and blocks Add Project on a missing
  one. Where possible it lets the Operator fix it in place: the Linear installation through
  `LinearInstallationView`. Otherwise it opens the matching Settings → General section.

## Every step

- **Prototype code is a source, not a dependency.** The app never links `Packages/Prototypes`.
  Code is moved into the app or into `YellowhammerKit`, then edited there. Remove `#if DEBUG`,
  fixtures and variant switches.
- **No brand values.** Map `WizardTheme` onto HIG defaults and the existing `DesignSystem`.
- **Use the glossary's terms** in type names and UI copy.
- **The fixture guard.** A step that runs `yh` when it appears must skip it under an overridden
  config dir that has no stub. If it does not, UI tests reach real Linear.
- **Sidekicks.** The sidekick's effort is set by its frontmatter (`medium`) and cannot be changed
  per call; only the model can. Every brief bans `git checkout`, `git restore` and `git stash`.
- **Done when**, in addition to the step's own line: `swift test --package-path
  Packages/YellowhammerKit` is green, the app builds, `swiftlint lint --strict` adds no new
  violations, and the story's acceptance criteria are listed as met or explicitly not met.
- One step is one layer in a `gh stack`, put on top of any open stack.

---

### [x] H1.1 The draft and its rules, under test

- **Work** — Move `AddProjectDraft` (with `+Navigation` and `+Summaries`), `BoundsDraft`,
  `WizardStep` and `WizardStepStatus` out of the prototype. Put the pure value logic (step order,
  each step's status, summaries, validation) where Swift Testing can reach it. That is
  `YellowhammerKit` if it needs no SwiftUI. Then decide how this connects to `SetupWizardModel`:
  either the draft becomes the model's state, or the model adapts to the draft.
  - **Setup readiness.** A value saying whether each machine-wide prerequisite is present: the
    Linear installation, the Operator identity, at least one agent CLI with a route. It is built
    from what `yh doctor` and the config already report. It blocks Add Project while one is
    missing.
  - **Bounds after setup.** After a successful `yh setup --init`, the model writes changed Bounds
    through `ProjectConfigurationModel.save()`, and surfaces a refusal as described above.
  - Nothing visible changes yet.
- **Lead** — Opus 5.5, High effort. Designs the connection to `SetupWizardModel` and the readiness
  value.
- **Sidekick** — Sonnet 5.5 (`model: sonnet`). Moves the code and writes the tests; this is a
  cross-module brief.
- **Done when** — Tests cover: each step's status; going from step to step in the hub; the
  summaries; a draft becoming a `SetupInvocation`; readiness blocking on each missing
  prerequisite; Bounds written only after a successful run, not when unchanged, and a refusal
  leaving the Project in place. The current sheet and `AddProjectUITests` still pass.
- **Status** — Done on 2026-10-02 (spec b9826d6). `AddProjectDraft` (with `+Navigation`,
  `+Summaries`, `+Invocation`), `AddProjectContext`, `Bounds+Fields` and `SetupReadiness` are in
  `Config`, the only linked product they fit without a human in Xcode. Two names changed: the
  steps are `AddProjectDraft.Step`, with Hub4's six (Project and Linear project are separate), and
  `AddProjectDraft.StepStatus`. Config's existing `Bounds` replaces the prototype's `BoundsDraft`.
  **The draft became the model's state.** `SetupWizardModel.draft` replaces its Project and
  scheduled-job fields, `buildInvocation()` starts from `draft.setupInvocation`, and Bounds go
  through `ProjectConfigurationModel.save()` after a successful run (`boundsFailure`). The old
  sheet keeps its own validator and copy until H3.1. It does not gate on `readiness`, because it
  still has the steps that set up those prerequisites. 54 new tests in `ConfigTests`. All 9
  `AddProjectUITests` pass. **Gaps for H2.1:** `yh setup` takes no `[schedule]` flags, so the draft
  has no Night window and the jobs step can only show the defaults. `SetupChoices` lists teams but
  not Linear projects, so Hub4's choice cards have no list to pick from. Both need Engine work or a
  read-only step body.

### [ ] H2.1 Hub4's step bodies in the app

- **Work** — Move `WizardBlocks`, `WizardRepoList`, `WizardStepBody` (with `+SpecAndBounds`),
  `WizardStepContent` and `WizardTheme` into `Features/AddProject`. Keep only the components Hub4
  uses (`hub4Components`: locked-token identity, choice-card Linear project, option-card spec,
  sentence Bounds) and delete the others. Add the readiness panel: one row per missing
  prerequisite, with a fix in place (`LinearInstallationView`) or a button that opens the matching
  Settings → General section. Connect each body to the draft from H1. They are not shown yet.
- **Lead** — Opus 5.5, Medium effort. Reviews the result against the Hub4 preview.
- **Sidekick** — Haiku 4.5 (default). This is mechanical; if it comes back `PARTIAL`, re-brief it
  as Sonnet 5.5.
- **Done when** — Each body and the readiness panel have an Xcode Preview in the app target and
  render against the H1 draft. No prototype type is referenced. The current sheet is unchanged.
- **Status** — Code in on 2026-10-02 (spec b9826d6). **Not ticked: the previews are not yet seen to
  render.** They compile against `AddProjectDraft.preview`, but Xcode Previews time out launching the
  app target for every preview, the existing `Theme+Preview` included. Moving `@main` from
  `AppLaunch` to the `App` did not help. Tick this step once they render. The bodies are in
  `Features/AddProject`: `WizardStepBody` (one per `AddProjectDraft.Step`, six `#Preview`s),
  `WizardBlocks`, `WizardRepoList` (cards only), `+SpecAndBounds`, `+Jobs`, and
  `SetupReadinessPanel`. `WizardTheme` became DesignSystem tokens and
  `AddProjectDraft.StepStatus.style`. `SettingsRequest` can name a section to open. The readiness
  panel's identifiers are `setup-readiness-*` and `setup-open-settings-*`. Only `JobsSections` and
  `WizardProblemList` came from `WizardStepContent`. The run view, status icon, sidebar row and
  footer are hub chrome, so they move in H3.1. **Departures from the Hub4 preview, from H1.1's
  gaps:** an existing Linear project is a pasted id, not a list, and the jobs step shows the
  `Schedule()` defaults read-only.

### [x] H3.1 Swap the sheet to Hub4

- **Work** — Replace `SetupWizardView` with Hub4's layout: the readiness panel when something is
  missing, then the hub, the step bodies, and the `addProjectConfirmation` alert before
  `yh setup --init`. Remove the Linear, Operator identity and Agent CLI routing steps from the
  sheet. Keep the P18.17 behaviour: Cancel is disabled and the sheet cannot be dismissed while
  setup runs, failure shows Close, success shows Done, and `ProjectAdditions` fires. Update
  accessibility identifiers and rework `AddProjectUITests` for hub navigation and readiness.
  Delete the losing variants from `Packages/Prototypes` (keep Hub4 as the reference), or delete the
  target if no one needs it.
- **Lead** — Opus 5.5, High effort. Runs the UI tests itself; they do not run in a sidekick.
- **Sidekick** — Sonnet 5.5 for the view swap and the prototype cleanup only.
- **Done when** — A Project is added through the Hub4 sheet from both sidebars and from onboarding.
  With no Linear installation the sheet blocks and offers the fix. `AddProjectUITests` passes.
  `testWizardDrivesSetupToCompletion` is known to be flaky on main: report a timeout there as that
  flake, not as a pass. Deep links are checked by hand.
- **Status** — Done on 2026-10-02 (spec b9826d6). `SetupWizardView` is Hub4's hub
  (`+Hub`, `WizardRunView`): a sidebar of the six steps, the open step's body, and a footer with what
  is still needed and Add Project, which confirms the id before `yh setup --init`. Until the Linear
  installation has been checked the sheet says so; while a prerequisite is missing the readiness panel
  replaces the hub. Check Again, or the sheet's window becoming key, reads the machine again. The
  sheet sets nothing machine-wide: `yh setup --init` gets only `draft.setupInvocation`, and the teams
  come from `--print-choices` once Linear is installed (fixture-guarded). The Linear, Operator identity
  and Agent CLI routing steps and `SetupWizardView+Linear.swift` are gone. P18.17's behaviour is kept,
  and Done now appears only after the Bounds write and the notification check.
  `AddProjectUITests` (11 tests) pass, `testWizardDrivesSetupToCompletion` included. They add a
  Project from both sidebars and from onboarding, and check that a Mac with nothing set up is
  blocked and that installing Linear in place opens the hub. Folder picks come from
  `-YellowhammerFolderPickerStub`, and the `yh` stub takes `YH_STUB_LINEAR_INSTALLED`. Deep links,
  by hand against a scratch configuration: `yellowhammer://project/demo` scoped the running app's
  window to Demo, and an unknown id opened a second window; its text was not read. This step does not
  touch deep-link routing. The prototype keeps only Hub4, as the reference while the app-target
  previews time out (H2.1). **Acceptance criteria (Add Project wizard):** the "+" in both sidebars,
  the sheet, the wizard as the only guided flow, and Cancel leaving no Project file are met and
  tested. The new row in both sidebars is built but not exercised by a test, as in P18.17: the stub
  `yh --init` writes no Project file. **Gap, not fixed here (#281):** on a fresh Mac no screen in the app can
  declare an agent CLI. Settings → Agent CLIs only lists and probes, and with no `config.toml` it
  offers "Add a Project…", which leads back to this sheet. The readiness panel's Agent CLIs button
  therefore cannot clear that row on a fresh Mac. The first Project needs `yh setup` in a terminal, or
  a hand-edited `config.toml`. The old sheet had the same gap in another form: `--install-linear`
  writes `config.toml` first, so the `--cli` and `--route` passed to `--init` afterwards were ignored.
  **Fixed since (#281):** Settings → Agent CLIs declares a registered agent CLI (`claude`, `codex`)
  with an optional executable, and points to the base Routing Table while no route names a declared
  CLI. On a fresh Mac, installing Linear in the readiness panel writes `config.toml`, so the Agent
  CLIs row can then be cleared in Settings without a terminal.
