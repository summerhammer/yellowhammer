# Release checklist

Run this checklist for every release, in order (roadmap P16.7). Every step is required unless it
says otherwise, and a failed step blocks the release.

Releases are cut by **release-please**, not by hand-tagging. `.github/workflows/release.yml`
watches `main` and keeps one open release pull request, titled `chore(main): release X.Y.Z`, whose
body is the changelog computed from Conventional Commits since the previous release. **Merging
that pull request publishes the release**: release-please creates tag `vX.Y.Z` and a draft GitHub
Release, and the same workflow run then calls `.github/workflows/release-build.yml` to build, sign,
notarize, package and publish the artifacts, un-drafting the release when it succeeds. Until the
build finishes, the release stays a draft and `releases/latest/download/appcast.xml` (the update
feed) still points at the previous release. So everything that can be checked before the merge is
checked before it (part 1). Only the checks that need the published artifact come after (part 3).
Part 4 says how to withdraw a release when one of them fails.

Record each run as described in [Record the run](#5-record-the-run).

In the commands below, `$VERSION` is `X.Y.Z`, `$TAG` is `vX.Y.Z`, and `$PR` is the release pull
request's number.

Never create a `vX.Y.Z` tag by hand and never push one — release-please's GitHub App token is the
only thing that creates a release tag.

## 1. Before merging the release PR

Find the open release pull request and check it out:

```sh
gh pr list --search "chore(main): release" --state open --json number,title
gh pr checkout "$PR"
```

Every check below runs against this checkout — the release pull request's head, i.e. the same
commit as `main` when it was opened.

### 1.1 CI green on the release PR

```sh
gh pr checks "$PR"
```

Each of these checks must show `pass`: CI (its `Lint`/`Test`/`Build` jobs, or `Skipped` — the
release PR touches only `CHANGELOG.md` and `.release-please-manifest.json`, so CI's own
documentation-only path detection reports those jobs as skipped, which still satisfies a required
check), PR title, Commits, Deployment target, Glossary, Module boundaries, Rehearsal fixtures,
Rehearsal suite, Scratch Linear environment, Secret scan, and Shell-not-host harness.

- `cancelled` is **not** green. Re-run it: `gh run rerun <databaseId>`.
- A failure with zero steps is a billing failure, not a test failure. The run's annotation says
  "The job was not started because recent account payments have failed". Fix the billing, then
  re-run it. It is still not green until it passes.
- Release-please rewrites the release PR (force-pushes a new head) every time `main` gains a
  release-worthy commit while it is open. If the head changes after you last checked it, redo
  every check in this section against the new head — `gh pr checkout "$PR"` again.

### 1.2 Probe drift check green

Required, and **manual**, on the release machine: the Mac whose Ledger holds the previous Probe
Results, with `claude` and `codex` installed and authenticated. Drift is computed against the
previous result in that machine's Ledger, so a machine with no earlier results cannot show drift.

Use the `yh` from the build in [1.3](#13-rehearsal-suite-green-on-the-release-pr):

```sh
.build/app/Build/Products/Debug/Yellowhammer.app/Contents/MacOS/yh probe --all
```

A nonzero exit, or any `drift since the previous probe` line that names a target, blocks the
release. [doc/probe-drift-check.md](probe-drift-check.md) (section 2) tells how to check the
latest upstream CLI versions and what to do about drift.

The scheduled `.github/workflows/probe-drift.yml` is not this gate. A hosted runner has no
authenticated agent CLIs, so it cannot probe, and no run of it has passed (#199).

### 1.3 Rehearsal suite green on the release PR

Required. A failed scenario blocks the release.

This step stays **manual** until a self-hosted Apple Silicon runner with Orca ADE and the scratch
Linear installation exists (`.github/workflows/rehearsal-suite-live.yml` is written for that runner
and will take over this step once it is registered).

1. Build the app (on the release PR checkout from [1](#1-before-merging-the-release-pr)):

   ```sh
   xcodebuild -project Yellowhammer.xcodeproj -scheme Yellowhammer -derivedDataPath .build/app build
   ```

2. Run the suite and record evidence, with a clean working tree:

   ```sh
   python3 scripts/rehearsal-suite/release_gate.py record \
       --app .build/app/Build/Products/Debug/Yellowhammer.app --team YLH \
       --evidence-directory .build/release-evidence
   ```

3. Check the verdict:

   ```sh
   python3 scripts/rehearsal-suite/release_gate.py check --evidence-directory .build/release-evidence
   ```

   A nonzero exit blocks the release — do not proceed until it passes.

4. Attach the evidence directory to the release after it is published (part 3), e.g. zip it and
   attach it as a release asset: `suite.log`, `journals/` (a Journal snapshot per scenario step),
   `night-cards.md` (every Night Card the run created, linked), and `verdict.json`.

### 1.4 Spec conflicts from P1.1 checked for new answers

Roadmap item P1.1 raised spec conflicts found while building the roadmap. Re-check each one that
is still open against the spec's current `main` (`../yellowhammer-spec`, `git pull` first). The
roadmap names each conflict; the table below says where to look and records the last answer.

| P1.1 | Where to read in the spec | Last checked | Status |
|---|---|---|---|
| 1 | `shift-scheduling/fire-an-act-on-schedule` | spec 7a3ed29 | Answered: no machine-wide Bounds left |
| 2 | `shift-scheduling/open-and-close-the-night-card` | spec 7a3ed29 | Answered: no machine-wide Bound criterion left |
| 3 | `loop-state/record-failure-cause-recurrence` | spec 7a3ed29 | Answered: no machine-wide running totals left |
| 4 | `docs/tech/system-overview.md` | spec 7a3ed29 | Answered: no compare-and-reserve, no Orca terminal |
| 5 | `docs/tech/stack.md` → Notable Constraints | spec 7a3ed29 | Answered: Orca ADE owns Worktrees only |
| 6 | `landing/open-one-pull-request-per-repository` | spec 7a3ed29 | Answered: no cost in the pull request body |
| 7 | `bounds/escalate-a-question-to-the-operator` | spec 7a3ed29 | **Open**: the acknowledgement strings are still an open criterion |
| 8 | `board-projection/read-board-changes-by-delta` and the feasibility probes table | spec 7a3ed29 | Answered: both use the `comments` root |
| 9 | `routing/overview` → Known Constraints | spec 7a3ed29 | Answered: the no-repeat rule cites OQ13 |
| 10 | `docs/requirements/vision/risks.md`, assumption A20 | spec 7a3ed29 | Answered: A20 is used once |

For each row still **Open**: read the spec at its current `main`. If it now has an answer, update
the row. If the code built against the old text must change, open an issue for it before the
release. Record the spec commit you checked against in the table and in the run record. Do not edit
the spec from this repo.

### 1.5 Release notes preview: spec commit and story IDs

`release-build.yml` sets the published release's body to the release-please changelog plus a
"Spec" section, generated by `scripts/release/release-notes.sh` from the `Spec: <epic>/<story> @
<sha>` lines in the commit messages since the previous release. Read the changelog and preview the
spec section before merging.

The changelog is the release PR's own body:

```sh
gh pr view "$PR" --json body --jq .body
```

`release-notes.sh` needs a real tag to compute its commit range, so preview it against a throwaway
local tag of the real name, on the release PR checkout, then remove it immediately — a lingering
local tag of the name release-please is about to create collides on the next `git fetch --tags`:

```sh
git tag "$TAG"
scripts/release/release-notes.sh "$TAG"
git tag -d "$TAG"
```

The section must name the spec commit the release was built against and list its story IDs. If it
says "none cited", confirm that no commit in the range implements spec'd behavior:

```sh
git log --format='%h %s' "$(git describe --tags --abbrev=0 --match 'v*' "${TAG}^")..$TAG"
```

v0.1.1 was a release like this: its commits were fixes with no `Spec:` line. If a commit that
implements spec'd behavior has no `Spec:` line, write the corrected section to a file now. Apply it
after publishing (part 3). A re-run of the build job (`workflow_dispatch`) writes the release notes
again, so re-apply the correction after any re-run.

Redo this preview if the release PR's head changes before you merge it (see [1.1](#11-ci-green-on-the-release-pr)).

### 1.6 Update channel provisioning (P16.5)

Before the first release, and on every Sparkle key rotation, confirm the repository variable
`SPARKLE_PUBLIC_ED_KEY` and secret `SPARKLE_ED_PRIVATE_KEY` are set — see
[doc/update-channel.md](update-channel.md). `scripts/release/verify-release-build.sh` fails the
release job if the public key is empty or missing from the built app.

#### Known install-on-quit window (P16.5 / #188)

Sparkle gates the update download against live Leases, but once downloaded, Sparkle installs on
app quit without a second Lease check. Checks are manual and infrequent; operators who initiate a
check should install immediately rather than leaving an update staged across later scheduled
Acts. See [doc/update-channel.md](update-channel.md#known-unclosed-gap-a-lease-claimed-after-the-check-is-not-caught).

## 2. Merge the release PR

```sh
gh pr merge "$PR"   # squash, rebase, or merge — any strategy is fine, see CONTRIBUTING.md
gh run list --workflow release.yml --branch main --limit 1
gh run watch <databaseId>
```

Merging publishes the release: release-please's job in that run creates the tag and a draft
GitHub Release, then the `build` job in the same run calls `release-build.yml` for that tag. Watch
the whole run, not just release-please's part — the release stays a draft, and
`releases/latest/download/appcast.xml` stays on the previous release, until the `build` job
finishes and un-drafts it. Never also upload a local build.

If the `build` job fails, the tag and the draft release are left in place — do not delete either.
Fix the problem and re-run the build for the existing tag:

```sh
gh workflow run release-build.yml -f tag="$TAG"
```

## 3. After publishing

### 3.1 Notarization verified

The `build` job (in the `Release` run, not a separate workflow) must be green. Its "Notarize,
staple and verify" and "Package disk image" steps fail on any rejection (see
[doc/release-build.md](release-build.md)). Then verify the published app again, as a user
downloads it:

```sh
dir=$(mktemp -d)
gh release download "$TAG" --pattern 'Yellowhammer-*.zip' --pattern SHA256SUMS --dir "$dir"
(cd "$dir" && shasum -a 256 -c SHA256SUMS --ignore-missing)
ditto -x -k "$dir"/Yellowhammer-*.zip "$dir"
scripts/release/verify-notarized.sh "$dir/Yellowhammer.app"
```

All three checks in `verify-notarized.sh` must pass: `codesign`, `spctl` reporting
`source=Notarized Developer ID`, and `stapler validate`.

### 3.2 Installed-product verification (P16.6)

Required. Run on a clean Apple Silicon Mac with the published release artifact, following
[doc/installed-product-verification.md](installed-product-verification.md):

```sh
python3 scripts/release/verify_installed.py record \
    --app /Applications/Yellowhammer.app --project <verification Project id> \
    --evidence-directory ~/yh-evidence-<version>
python3 scripts/release/verify_installed.py check \
    --evidence-directory ~/yh-evidence-<version> --version <version>
```

A nonzero exit from `check` blocks the release. Attach the zipped evidence directory to the GitHub
release as `installed-verification-<version>.zip`.

### 3.3 Release notes on the release page

```sh
gh release view "$TAG" --json body --jq .body
```

The body must be the release-please changelog followed by the spec section previewed in
[1.5](#15-release-notes-preview-spec-commit-and-story-ids). If you wrote a corrected spec section
there, apply it now: `gh release edit "$TAG" --notes-file <file>`.

### 3.4 Evidence attached

The release carries the rehearsal suite evidence (1.3) and `installed-verification-<version>.zip`
(3.2).

## 4. If a check fails after publishing

The release is already in the update feed and is the download link. Withdraw it:

```sh
gh release edit "$TAG" --prerelease
gh api repos/summerhammer/yellowhammer/releases/latest --jq .tag_name
```

GitHub's latest release is the newest release that is neither a draft nor a pre-release. So after
the edit, `releases/latest` (the feed and the download link) goes back to the previous release. The
second command must print the previous tag. A Mac that already installed the withdrawn release
keeps it.

Then fix forward with the next release PR and its patch version. Never delete or recreate a
release tag: the build number comes from the tag's commit count, and Sparkle compares build
numbers to decide what is newer. v0.1.0 is the precedent: it failed installed-product verification
(check 2) after it was published, and v0.1.1 fixed it.

## Hotfixing a published release

Fix `main` first, and ship the fix in the next ordinary release PR — that is the common case.

Only when `main` cannot ship (e.g. unreleased work on `main` is not ready) does a hotfix need its
own branch: create `release/X.Y` from the published tag `vX.Y.Z`, cherry-pick the fix commit(s)
onto it, and release from that branch instead of `main`. Release-please is not yet configured to
run against a `release/X.Y` branch — set that up before relying on this path.

## 5. Record the run

Attach a record of the run to the GitHub release as `release-checklist-<version>.md`:

```markdown
# Release checklist: vX.Y.Z

Release PR: #<number>. Merge commit: <sha>. Spec checked against: <spec sha>. Run by: <name>, <date>.

- [ ] 1.1 CI green on the release PR (runs: <ids>)
- [ ] 1.2 Probe drift check green (`yh probe --all`, exit 0, no drift)
- [ ] 1.3 Rehearsal suite green (`release_gate.py check`, exit 0)
- [ ] 1.4 P1.1 spec conflicts re-checked (open rows: <list, or none>)
- [ ] 1.5 Release notes preview: spec commit and story IDs, or "none cited" confirmed
- [ ] 1.6 Update channel keys set
- [ ] 3.1 Notarization verified on the downloaded zip
- [ ] 3.2 Installed-product verification green (`verify_installed.py check`, exit 0)
- [ ] 3.3 Release notes on the release page
- [ ] 3.4 Evidence attached
```

A step that was not run is not ticked, and the record says why.
