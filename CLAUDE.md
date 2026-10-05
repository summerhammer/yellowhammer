# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

The Yellowhammer macOS **app** and the **Engine**, shipped as one artifact: a single
self-contained `.app`, Developer ID signed and notarized, distributed directly — not
the Mac App Store, and **not sandboxed** (no App Sandbox, no in-app purchase, no
receipt). Swift + SwiftUI, macOS only, Apple Silicon only. There is no iOS, web or
Linux surface, now or planned.

- **App** — the GUI. Machine-wide scope. A bounded local control surface.
- **Engine** — short-lived `author | build | land` invocations, each scoped to exactly
  one Project and fired by a `launchd` LaunchAgent (or cron) that setup generates. Not a
  daemon.

Yellowhammer never writes a line of code, and it never merges to main.

## Product spec

The authoritative product spec lives at `../yellowhammer-spec`. Read
`../yellowhammer-spec/skill.md` before working on spec'd behavior — it explains how to
find, read, and correctly apply it. Query it through the `spec` MCP server
(`spec_search`, `spec_read`, `spec_grep`, `spec_list`, `spec_glossary`) or `/spec-lookup`.

**Do not copy spec content into this repo.** Anything pasted here stops tracking the
spec the moment it lands, and nothing detects the drift. Read it from the spec repo at
the time you need it.

**Never edit the spec from this repo.** If it is wrong, incomplete, or contradicts
itself, say so and propose the change — a human applies it there.

### How much weight a spec document carries

Every spec document declares a `status`. Honor it:

- ADR `accepted` — **binding**. Do not contradict it without flagging the conflict.
  Currently ADR-001 (Ports), ADR-002 (Project is the top-level scope), ADR-003 (the Ledger).
- ADR `proposed` — under discussion. Do not build on it.
- Everything else is `draft` — direction, **not a contract**. That includes all of
  `docs/requirements/` and the whole OOUX object model. A `draft` object map is a
  sketch, not a schema.

A story's stable ID is its path, `<epic>/<story>`. **Never rename a story file** — that
changes its ID and breaks every citation of it. Read the epic's `overview.md` as well
as the story: business rules live in the epic. Acceptance criteria are the contract —
implement all of them, and say which ones you could not satisfy rather than quietly
dropping one.

## Ubiquitous language

`../yellowhammer-spec/docs/glossary.md` is authoritative. Use its terms verbatim — in
type and function names, SQLite columns, commit messages, and UI copy. Do not coin a
synonym for a term that already exists; if a concept you need has no entry, that is a
gap in the spec, so raise it.

- Capital-P **`Project`** is always ours; lowercase *Linear project* is Linear's. This
  spelling is load-bearing.
- `Card`, `Cycle` and `Worktree` are borrowed words whose Yellowhammer meanings are
  deliberately **narrower** than the tools they come from — read those three glossary
  entries first. A `Cycle` is neither a Linear cycle nor a milestone: its Cards are native
  sub-issues (`parentId`) of the Feature Issue.
- **Round is not Attempt.** A review asking for changes is a new *Round* (same worker,
  same worktree). An *Attempt* ends only on hard failure and re-dispatches on a
  different route. Conflating them makes "3 attempts, 2 rounds" incoherent.
- Name **vendors** — Linear, Orca ADE, GitHub, agent CLIs — in acceptance criteria and
  tests. Never name a Port.

## What the app must not do

These are rulings, not preferences. Violating one is a defect.

- **Shell, not host.** A Night must run correctly with the app never opened, and with
  it quit mid-Shift. If quitting the app can kill an Act, that is a defect.
- **It is not a board.** No state, queue, or triage step belongs in the app — triage
  happens in Linear. The app may trigger and display; it may never be where a decision
  is made or recorded. Anything demanding a decision surfaces as a board object.
- **No cross-Project view.** The app may read N Journals; it may not merge N Nights
  into a verdict. The landing screen's Sidebar lists every Project, but each Project's
  Pulse is computed from its own Journal alone — no element blends two Projects' data.
- **Read-only on every Journal.** The app writes nothing.
- **Nothing resident.** No daemon, no background service, no timer, no in-memory cache,
  no background watcher. Anything that must outlive a tick is written to the Journal or
  it does not exist.
- **Never schedules.** `launchd` (or cron) owns all scheduling; Orca ADE owns Worktrees only.
- **Notifications are fire-and-forget.** No acknowledgement, no retry, no state. Never
  branch behavior on whether one was delivered; never nag, and never treat a revoked
  setting as a fault.

## Architecture (ADR-001/002/003, binding)

Four Ports, named exactly: **Board** (Linear), **Workspace** (Orca ADE), **Dispatch**
(agent CLI adapters plus the Probe), **Publication** (GitHub).

- An adapter translates; it never decides. Outbox idempotency, lease revalidation and
  delta-read discipline sit **above** the Port.
- Vendor identifiers may cross a Port as opaque values. Vendor types, error shapes and
  query languages may not.
- **Do not protocol-wrap everything** — "Ports everywhere" was explicitly rejected.
  Apple frameworks (macOS Notification Center included), the Journal, the Ledger and
  local git are used directly. Local git is the `git` executable run from a concrete
  Yellowhammer-owned module and tested against fixture repositories, not behind a Port.

State ownership, no overlap: Linear owns intent; Orca ADE owns Worktrees; `launchd`
owns scheduling; the local SQLite **Journal** owns loop state, one per Project; the
**Ledger** owns machine-scoped state, one per machine. Nothing a single Project owns
moves into the Ledger. An engine invocation is scoped to one Project and has no handle
on its siblings. A Repo belongs to exactly one Project; declaring it twice is invalid
configuration, caught at setup.

Interruption wording is mandated: assert that "the Card is reclaimable, and no partial
state was written as if it were complete" — never that "the Card continues". Sleep is
more dangerous than a crash: the Lease is revalidated before every write. A crashed
Attempt is Crashed-Unknown, is consumed, and does not exclude its route.

## Testing

Swift Testing (`@Test` / `#expect`), not XCTest. Repo-local choice; the spec names neither.

`../yellowhammer-spec/docs/tech/system-overview.md` constrains what may be asserted.
Read it before writing tests for engine behavior. (There are no machine-wide Bounds;
the per-Project Bounds' arithmetic *is* assertable.) **Do not write tests asserting**
anything model-authored (diffs, review verdicts,
Architectural Briefs, authored DoD, conflict resolution), the engine-run Check, push,
PR creation or body, or attempt-completion behavior on crash and kill. A fixture green is not a green.

Three environments only — Development, Rehearsal, Production. There is no staging or
sandbox environment. A rehearsal Night stops at exactly three boundaries: it never
dispatches an agent CLI, never pushes, and never opens a pull request. It does **not**
stub Linear or Worktrees — a fake Board adapter in rehearsal is a defect, not an
optimisation.

## Local choices (this repo's, not the spec's)

- **Persistence: GRDB.** The Journal's claim-and-lease needs real local transactions;
  shelling out to `sqlite3` is ruled out.
- **Lint: SwiftLint** — `swiftlint lint`, `swiftlint --fix`. `swift-format` is not
  installed. A `PostToolUse` hook runs `swiftlint --fix` on edited Swift files.
- **Build: a thin committed Xcode project plus a local Swift package.** Tuist and a
  package-only build were considered and rejected. Swift 6 language mode everywhere.
  - `Yellowhammer.xcodeproj` holds only two targets, using buildable folders:
    `Yellowhammer` (the app, `dev.yellowhammer`) and `Engine` (a command-line tool,
    product `yh`, `dev.yellowhammer.engine`). The app embeds `yh` in `Contents/MacOS`
    through a Copy Files phase with Code Sign On Copy. The `Engine` target embeds its
    Info.plist in the binary so codesign uses the bundle identifier, not the file name.
    Debug and Release are the only build configurations: rehearsal is a runtime mode
    of a Night, never a build configuration or scheme.
  - `Packages/YellowhammerKit` holds all logic. Tests run with
    `swift test --package-path Packages/YellowhammerKit`; the app builds with
    `xcodebuild -project Yellowhammer.xcodeproj -scheme Yellowhammer build`.
  - Edit `.pbxproj` only for build settings. Adding targets, package products or
    capabilities is done in Xcode by a human.
- **Names.** The command is `yh` — its subcommands are the Acts, and they are written
  into every generated LaunchAgent, so they are a contract. A module is named after the
  glossary term it holds, and vendor code is named `<Vendor>Adapter` (`LinearAdapter`,
  `OrcaADEAdapter`, `GitHubAdapter`, `CLIAdapters`). No module is named after a Port
  (Apple already has a `Dispatch` module), and no type shares its module's name. TOML
  configuration lives in `Config` — not `Operator`, which is the human.
- **Modules exist to enforce the binding rules, and one is added only when its first
  real code lands.** `Engine` never imports an adapter (ADR-001); only
  `EngineCommand` wires adapters in. The app never links `Engine` (shell, not host).
  `Journal` and `Ledger` are separate modules (ADR-003). `Engine` never opens a Journal:
  `EngineCommand` opens the resolved Project's and hands it to the invocation, so nothing
  in `Engine` can address a sibling Project's (ADR-002). CI checks all of these
  (`scripts/ci/check_module_boundaries.py`, MB1–MB5).

## Decided — read the ruling, do not re-open

The spec's Decision Gates Ruling (`../yellowhammer-spec/docs/requirements/vision/risks.md`,
`#decision-gates-ruling-2026-09-15`) closed the decisions this section used to list. Read it
there; the repo-local consequences are:

- **Minimum macOS is 26.0.** It appears in two places, which must stay equal:
  `MACOSX_DEPLOYMENT_TARGET` in the project and `platforms` in `Package.swift` (CI checks).
- **Scheduling is `launchd`**, and `yh` runs from `Contents/MacOS`. `yh` does not post
  notifications itself: it launches `Yellowhammer.app` headless with
  `--post-notification`.
- **Local git is not behind a Port** (see Architecture). Needs `git` 2.38 or later.
- **Schema migrations are GRDB `DatabaseMigrator`s, forward-only, owned by the engine.**
  The Journal and the Ledger each have their own migrator in their own module. The engine
  migrates on open; the app opens every store read-only, never migrates, and refuses to
  read a store whose schema is newer than it knows. Never use `eraseDatabaseOnSchemaChange`
  outside tests.
  - **Pre-1.0, the Journal has exactly one migration** (`journal-schema-N`) that creates the
    whole schema in one shot. A schema change edits it in place and bumps `N`; both the
    engine and the app then refuse a Journal created by an older build, which is deleted
    and recreated. Do not add incremental Journal migrations until 1.0. The Ledger still
    uses incremental migrations, each never edited or reordered once shipped.
- **The app is a window app**: no `MenuBarExtra`, no login item, no background updater.
  Every decision screen is Linear's. Updates are Sparkle 2, user-initiated.
- **The main window is the landing screen: Sidebar, Pulse, Inspector.** The spec's
  Landing Screen Ruling (`risks.md#landing-screen-ruling-2026-09-28`) reopened G-6 for
  that one point; read it and the story `app/land-on-the-sidebar-and-pulse` there. The
  Pulse is being prototyped in Xcode Previews before it is built for real:
  `Packages/YellowhammerKit/Sources/Pulse/` holds the screen's view state (plain values) and
  the Journal read, `PulseSnapshot.read(from:asOf:)`, that fills it, and
  `Packages/Prototypes/Sources/PulsePrototypes/` holds the fixtures, the Playground and Gallery
  previews, and the variants, registered in `PulseVariant.all`. `Packages/Prototypes` is a
  throwaway package, one target per screen, that the app never links; render it with the
  screen's scheme (`PulsePrototypes`), so a preview builds neither the app nor `yh`. A
  variant renders only a `LandingSnapshot` and routes every way out through
  `openPulseDestination`; it never reads a Journal or runs `yh`. Roadmap Phase 18
  builds the Pulse for real.
- On-disk paths, the `[schedule]` and `[limits]` keys and their defaults are in the
  spec's ruling and `docs/tech/stack.md` — read them there, do not restate them here.

## Still open — raise them, do not invent them

- **Probe owed before the code that depends on it:** Linear exposing a threaded
  reply's parent comment to the Delta Read (G-8). The G-6 settle probe has run — read
  `docs/tech/investigations/2026-09-23-g6-settle-state-probe.md` in the spec.
- **Brand is entirely unfilled.** `../yellowhammer-spec/docs/brand/*.md` are
  unpopulated templates — the hex values are `#000000` placeholders and no fonts are
  chosen. The one real artifact is the semantic text-style table, which maps 1:1 onto
  SwiftUI `Font.TextStyle`. Use Apple HIG defaults; do not invent brand values.

## Git

`origin` is `summerhammer/yellowhammer`; `main` is the trunk. The umbrella at `..` and
`../yellowhammer-spec` are separate git repos — work only in this one unless asked.

Roadmap work ships as **stacked PRs via `gh stack`** — `gh stack init <branch>` for the
first layer, `gh stack add <branch>` for each one above it, then
`gh stack submit --auto --open`. Never hand-set a PR base. One roadmap item is one
layer; mark the item `[x]` in `doc/implementation-roadmap.md` in its own commit on that
layer.

Every pull request titled `feat`, `fix`, `perf` or `revert` carries the traceability line
(or `Spec-Exempt: <reason>` when no story applies; other title types, and pull requests Yellowhammer
itself opens from a Feature Branch whose last path segment starts with `yh-`, need neither):

```
Spec: <epic>/<story> @ <spec commit sha>
```

Cite story IDs in commit messages too. `/spec-cite` assembles the line.

Commit messages and pull request titles follow Conventional Commits (`type(scope): subject`;
`feat`, `fix`, `perf`, `revert`, `docs`, `refactor`, `test`, `ci`, `build`, `chore`; `!` or a
`BREAKING CHANGE:` footer for a breaking change) — see CONTRIBUTING.md's "Commits and releases"
section for the full rule and how it drives versioning. Releases happen only by merging the
release-please pull request; never create or push a `vX.Y.Z` tag by hand.
