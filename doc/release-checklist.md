# Release checklist

Run this checklist for every release, in order (roadmap P16.7). Every step is required unless it
says otherwise, and a failed step blocks the release.

The order matters because pushing a `vX.Y.Z` tag **publishes** the release:
`.github/workflows/release-build.yml` builds, notarizes and publishes it to GitHub Releases, and the
update feed (`SUFeedURL`) reads `releases/latest/download/appcast.xml`. So everything that can be
checked before the tag is checked before the tag (part 1). Only the checks that need the published
artifact come after it (part 3). Part 4 says how to withdraw a release when one of them fails.

Record each run as described in [Record the run](#5-record-the-run).

In the commands below, `$VERSION` is `X.Y.Z` and `$TAG` is `vX.Y.Z`.

## 1. Before the tag

Work on the release commit: a commit on `main`, pushed, with a clean working tree.

### 1.1 CI green on the release commit

List the workflow runs on the release commit:

```sh
sha=$(git rev-parse HEAD)
gh run list --commit "$sha" --limit 50 --json workflowName,event,status,conclusion,databaseId \
    --jq '.[] | "\(.workflowName)\t\(.event)\t\(.status)\t\(.conclusion)\t\(.databaseId)"'
```

Each of these push workflows must show `completed success`: CI, Deployment target, Glossary,
Module boundaries, Rehearsal fixtures, Rehearsal suite, Scratch Linear environment, Secret scan,
Shell-not-host harness, and Release scripts when it ran.

- `cancelled` is **not** green. Re-run it: `gh run rerun <databaseId>`. (v0.1.1 was tagged on a
  commit whose CI run was cancelled.)
- A failure with zero steps is a billing failure, not a test failure. The run's annotation says
  "The job was not started because recent account payments have failed". Fix the billing, then
  re-run it. It is still not green until it passes.
- CI skips commits that change only `doc/`, `docs/` or Markdown files, and Release scripts runs
  only for `scripts/release/` changes. If one of them did not run on the release commit, take its
  newest green run on an ancestor, and confirm that only skipped paths changed since:
  `git diff --stat <that commit>..HEAD`.

### 1.2 Probe drift check green

Required, and **manual**, on the release machine: the Mac whose Ledger holds the previous Probe
Results, with `claude` and `codex` installed and authenticated. Drift is computed against the
previous result in that machine's Ledger, so a machine with no earlier results cannot show drift.

Use the `yh` from the build in [1.3](#13-rehearsal-suite-green-on-the-release-commit):

```sh
.build/app/Build/Products/Debug/Yellowhammer.app/Contents/MacOS/yh probe --all
```

A nonzero exit, or any `drift since the previous probe` line that names a target, blocks the
release. [doc/probe-drift-check.md](probe-drift-check.md) (section 2) tells how to check the
latest upstream CLI versions and what to do about drift.

The scheduled `.github/workflows/probe-drift.yml` is not this gate. A hosted runner has no
authenticated agent CLIs, so it cannot probe, and no run of it has passed (#199).

### 1.3 Rehearsal suite green on the release commit

Required. A failed scenario blocks the release.

This step stays **manual** until a self-hosted Apple Silicon runner with Orca ADE and the scratch
Linear credentials exists (`.github/workflows/rehearsal-suite-live.yml` is written for that runner
and will take over this step once it is registered).

1. Build the app:

   ```sh
   xcodebuild -project Yellowhammer.xcodeproj -scheme Yellowhammer -derivedDataPath .build/app build
   ```

2. Run the suite and record evidence, on the release commit, with a clean working tree:

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

`release-build.yml` writes the release notes with `scripts/release/release-notes.sh`, from the
`Spec: <epic>/<story> @ <sha>` lines in the commit messages since the previous tag. Read them before
the tag is pushed. Create the tag locally first, because the script needs it:

```sh
git tag "$TAG"
scripts/release/release-notes.sh "$TAG"
```

The notes must name the spec commit the release was built against and list its story IDs. If they
say `Built against spec commit: none cited`, confirm that no commit in the range implements spec'd
behavior:

```sh
git log --format='%h %s' "$(git describe --tags --abbrev=0 --match 'v*' "$TAG^")..$TAG"
```

v0.1.1 was a release like this: its commits were fixes with no `Spec:` line. If a commit that
implements spec'd behavior has no `Spec:` line, write the corrected notes to a file now. Apply them
after publishing (part 3). A re-run of the release job writes the notes again, so apply them
again after any re-run.

### 1.6 Update channel provisioning (P16.5)

Before the first tagged release, and on every Sparkle key rotation, confirm the repository
variable `SPARKLE_PUBLIC_ED_KEY` and secret `SPARKLE_ED_PRIVATE_KEY` are set — see
[doc/update-channel.md](update-channel.md). `scripts/release/verify-release-build.sh` fails the
release job if the public key is empty or missing from the built app.

#### Known install-on-quit window (P16.5 / #188)

Sparkle gates the update download against live Leases, but once downloaded, Sparkle installs on
app quit without a second Lease check. Checks are manual and infrequent; operators who initiate a
check should install immediately rather than leaving an update staged across later scheduled
Acts. See [doc/update-channel.md](update-channel.md#known-unclosed-gap-a-lease-claimed-after-the-check-is-not-caught).

## 2. Tag and publish

```sh
git push origin "$TAG"
gh run list --workflow release-build.yml --limit 1
gh run watch <databaseId>
```

Pushing the tag publishes the release. Never also upload a local build.

## 3. After publishing

### 3.1 Notarization verified

The Release build run must be green. Its "Notarize, staple and verify" and "Package disk image"
steps fail on any rejection (see [doc/release-build.md](release-build.md)). Then verify the
published app again, as a user downloads it:

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
    --production-linear-client-id <production client id> \
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

The body must match the preview from [1.5](#15-release-notes-preview-spec-commit-and-story-ids).
If you wrote corrected notes there, apply them now:
`gh release edit "$TAG" --notes-file <file>`.

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

Then fix forward with the next patch version. Never move or re-push a tag that was published: the
build number comes from the tag's commit count, and Sparkle compares build numbers to decide what
is newer. v0.1.0 is the precedent: it failed installed-product verification (check 2) after it was
published, and v0.1.1 fixed it.

## 5. Record the run

Attach a record of the run to the GitHub release as `release-checklist-<version>.md`:

```markdown
# Release checklist: vX.Y.Z

Release commit: <sha>. Spec checked against: <spec sha>. Run by: <name>, <date>.

- [ ] 1.1 CI green on the release commit (runs: <ids>)
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
