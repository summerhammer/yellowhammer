# Verification delivery: publish what was pushed (#708) and observe a merge by pull request read (#698) — roadmap

This roadmap builds two accepted rulings and one disclosure:

- **OQ191**, *a Cycle judges and publishes what it pushed*
  ([#708](https://github.com/summerhammer/yellowhammer/issues/708)), with the Pushed Tip ruling of
  2026-10-30;
- **OQ197**, the separate-Checks sentence in the known limitation;
- **OQ190**, merge detection by pull request read
  ([#698](https://github.com/summerhammer/yellowhammer/issues/698) and #712–#718).

It also records the #708 cross-repository reproduction, which feeds OQ198. It is separate from
`implementation-roadmap.md` and does not renumber it.

**Spec.** Read these from the spec repository, through the `spec` MCP. Do not copy them here.

- Rulings in `docs/requirements/rulings/`:
  - `2026-10-29-cycle-publishes-what-it-pushed-ruling.md` (OQ191, items 1–9);
  - `2026-10-30-pushed-tip-ruling.md`;
  - `2026-10-30-separate-checks-disclosure-ruling.md` (OQ197);
  - `2026-10-28-merge-detection-ruling.md` (OQ190, items 1–29).
- Stories:
  - `landing/open-one-pull-request-per-repository`: `#publication-retry`, `#remote-tip-check`,
    `#unpublished-commits-pin`, `#judged-commit-in-body`, `#any-merge-method`;
  - `verification/verify-a-feature-clause-by-clause`: `#judged-checkout`,
    `#recorded-check-results`, `#report-limitation`;
  - `feature-authoring/select-the-next-feature`: `#pushed-tip`, `#merge-test`,
    `#pull-request-read`, `#stacked-content-test`, `#net-zero-branch`, `#release-gate`,
    `#route-out`;
  - `morning-report/write-the-night-summary`: `#unmerged-standing-line`, `#stack-full-skip`,
    `#pull-request-read-notes`, `#publish-what-was-pushed-notes`;
  - `shift-scheduling/diagnose-the-installation`: `#check-5-code-hosting-connections-github`;
  - `app/land-on-the-sidebar-and-pulse`: `#pull-request-state`.
- Glossary: *Pushed Tip*, *Observed Merge*, *No-Pushed-Branch Outcome*.

**Harness.** The OQ191 test-first harness is on `main` (`c0db7c6c`, #721). Run it with:

```
swift test --package-path Packages/YellowhammerKit --filter OQ191
```

Each step below names the harness tests it turns green. To finish a step, do three things:

- replace the step's `OQ191Probe` bodies with real calls, keeping their signatures;
- delete the matching `withKnownIssue` wrappers;
- re-check by hand the tests that pass vacuously: J6, E21, E31, E36, E37 and E41.

Test IDs (J = Journal, R = Repositories, E = EngineCommand) follow the inventory in the Track A
pull request.

## Decisions taken for this work (Operator, 2026-10-30)

1. **The Pushed Tip is stored in a new `pushed_tip` table.**
   - Key: `(cycle_id, repository)`.
   - Write: `INSERT OR IGNORE`, so the first write wins.
   - `feature_repository.landed_commit` is dropped. The Journal schema is edited in place and its
     number bumped.
   - Every reader goes through `pushedTip(cycleID:repository:)` or `pushedTips(featureID:)`.
     `pushedTips(featureID:)` reads the latest Cycle's tip for each repository, so OQ193 stays
     open.
   - N is unaffected: it is `touched_repos` minus the recorded No-Pushed-Branch Outcomes.
2. **OQ194: other lanes still publish.**
   - When one lane's remote Feature Branch is at another commit, or absent, that lane opens no
     pull request and keeps its Worktree held. The Cycle stays unlanded.
   - Lanes whose remote matches still open their pull requests and release their Worktrees.
   - A spec issue records this as built.
3. **OQ195: a touched repository with no held Worktree forces a fresh layout.**
   - That repository counts as "not exact and clean", so every repository is checked out fresh.
   - Each repository keeps its held Worktree's relative path. The lane-less repository goes at
     `<root>/<repository>`.
   - A spec issue records this as built.
4. **#698 expected items 2 and 3 are out of scope.** These are surfacing a stacked dirty base and
   stopping an identical rejection from being retried. They are filed as spec issues.

## Branches

```
main ← feat/708-publish-what-was-pushed   (Track A + C; one commit per step)
     ← feat/698-observe-merge-by-pr-read  (Track B; one commit per issue)
```

- Commits say `Refs #<issue>`, never `Closes`.
- Each step ticks its own box below, inside its step commit.

## Track A — #708, OQ191 and OQ197

- [x] **A1 — The Pushed Tip is written once per (Cycle, repository), and a retry never re-pushes.**
  Items 1 and 2.
  - **Journal.** Add `pushed_tip` and drop `landed_commit`. Move every reader to the new API:
    `testedTips`, `ReleaseGate` (B), the landed-pin release, `AuthoringBases` / `EffectiveBase`,
    and the Pulse UI-test fixture.
  - **Land Act.** When a Pushed Tip is recorded, the retry neither calls the push seam nor pins
    again.
  - **Harness.** J1, E1, E2, E4 and E7 turn green. E6, E9 and E11 stay green.
  - **Old-rule tests.** Rewrite `laterPushOverwrites` and `laterPushMovesTheRecordAndThePin`.
- [x] **A2 — The Verification record names each repository's judged commit, its checkout kind and
  the "no pushed branch" mark.** These are written in the same transaction as the verdicts. A record
  written before this rule reads "judged commit not recorded" and is never backfilled. Items 3, 5
  and 7.
  - **Harness.** J2, J3, J4, J5 and J8 turn green.
- [x] **A3 — The verifier judges checkouts at the Pushed Tips.** A No-Pushed-Branch repository is
  judged at `feature_base.base_commit`. Items 2, 5, 7 and 8.
  - **Reuse.** Held Worktrees are reused only when every one of them is exact and clean. Otherwise
    every repository gets a fresh checkout (`clone --shared`) in a shared layout.
  - **Instruction.** It names the judged commit.
  - **Harness.** R5, R6, E22, E23, E26, E38, E39, E40, E42 and E43 turn green. Hand-check E37 and
    E41.
  - **Spec issue.** File OQ195 as built.
- [x] **A4 — The remote tip check runs before every pull request open.** Item 4.
  - **Read.** `git ls-remote`, with the push's credential.
  - **At another commit or absent.** The pull request does not open, and the failure names both
    commits.
  - **Unreadable.** It counts as a failed publication.
  - **Other lanes** still publish.
  - **Harness.** R1–R4 and E14–E21 turn green. E13 stays green.
  - **Spec issue.** File OQ194 as built.
- [x] **A5 — At release, a HEAD that is not the Pushed Tip is pinned and reported as not
  published.** The pin is a ref outside `refs/heads/` and is never pushed. The report is also made
  at Verification time. Items 1, 2, 5, 6 and 9.
  - **Harness.** R7–R10, E5, E24, E27–E30 and E44 turn green. E32, E33 and E45 stay green.
    Hand-check E31.
  - **Spec issue.** File a pin failure keeping the Worktree held (lead draft).
- [ ] **A6 — The pull request body shows each repository's short judged commit.** Item 3.
  - **Harness.** E34 and E35 turn green. Hand-check E36.
- [ ] **A7 — OQ197: the separate-Checks sentence is added to the limitation.** It applies when
  `touched_repos` has 2 or more repositories, on both the Feature Card and the pull request body.
  - **Tests.** New tests cover one versus two repositories, on both surfaces.

## Track C — #708 investigation step 2 (feeds OQ198)

- [x] **C1 — Try to reproduce two cases with two disposable local repositories:**
  - two Checks that are each green while the combined state fails;
  - a combined state that is green while an intermediate merge state fails.

  The commands and results go in `doc/investigations/708-cross-repo-reproduction.md`. There is no
  tested revision matrix and no merge-order advice.

## Track B — #698, OQ190 (started after A1)

Steps are ordered by dependency:

- B1 records the landing commit, which B2's anchor and the release gate (A) need. B1 builds the
  first-parent scan too, because the scan's commit C *is* the content landing commit.
- B3 is the pull request read that #717, #714 and #715 need.
- #716 edits the same standing line as #714, so it comes after it.
- #718 needs #717's stored state.

- [ ] **B1 #713 — Record the Observed Merge's landing commit.**
  - **Ancestry.** The landing commit is the oldest first-parent commit that contains the tip.
  - **Content.** The landing commit is the first first-parent commit C where
    `merge-tree --write-tree C <tip>` writes `C^{tree}`. This scan replaces the test against
    mainline's head (OQ190 item 24).
  - **Release gate.** (A) tests the tag against the landing commit.
- [ ] **B2 #712 — A stacked Feature is tested by content only after the Feature below it has its
  Observed Merge.**
  - The scan starts at that Feature's landing commit.
  - The recorded base is the base of the three-way merge and of the net-change check.
  - $U$ is tested oldest first.
- [ ] **B3 #698 — Read the pull request.**
  - Add a second Publication Port operation and a GitHub adapter GET.
  - The merge test's second rung: the pull request is merged, and its merge commit is in
    mainline.
  - A failed read falls through to the content test, plus a `PullRequestReadFailed` event.
- [ ] **B4 #717 — Store the last observed pull request state per (Feature, repository).**
  - The state is `open`, `merged` or `closed without merge`, with when it was observed.
  - A failed read leaves the last state in place.
- [ ] **B5 #714 — Night Summary notes:**
  - `pull_request_read_failed`;
  - `[closed without merge: <repo>]`;
  - `[merged into <branch>, waiting for it: <repo>]`;
  - a Feature Branch with more than one pull request.
- [ ] **B6 #716 — Recommend no merge method.**
  - Copy: "Merging the pull request by any method releases the next Feature."
  - The Night Card lines carry the route out (`git merge -s ours`).
  - `MergeCommitRecommendation` goes.
- [ ] **B7 #715 — `yh doctor` Check 5 reports whether the connection can read pull requests.**
  - A connection that cannot read them is a warning.
  - A read that cannot be verified is unverified.
- [ ] **B8 #718 — The Pulse shows each repository's last observed pull request state.**
  - It shows the time observed.
  - It marks when the latest read failed.
  - It shows nothing when no state was ever observed.

## Owed after release (not run by these steps)

- A moved-branch land retry on a real Night: the pull request opens at the Pushed Tip, and the
  later commits are pinned and reported.
- A squash-merged predecessor with post-land edits releases the next Feature on a real Night.
