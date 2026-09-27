# Release build (P16.2)

A Release build from a tag carries the tag's version in both the app and `yh`.

## What Release configuration does

Both targets (`Yellowhammer`, `Engine`) build Release Manual-signed with the
**Developer ID Application** identity, hardened runtime, and a secure timestamp
(`--timestamp`) — see [doc/signing-identity.md](signing-identity.md). `yh` is embedded
into `Contents/MacOS` via a Copy Files phase with Code Sign On Copy, and carries its own
Info.plist embedded in the binary so codesign uses `dev.yellowhammer.engine`, not the
file name. Release omits the injected `get-task-allow` entitlement, which notarization
refuses, and builds `arm64` only (Apple Silicon).

Minimum macOS is 26.0 (spec G-2), CI-checked by `deployment-target.yml`.

## Versioning scheme

A release tag matches `vX.Y.Z` (no pre-release suffixes). From it:

- `MARKETING_VERSION` = `X.Y.Z` — CFBundleShortVersionString.
- `CURRENT_PROJECT_VERSION` = the number of commits reachable from the tag
  (`git rev-list --count <tag>`) — CFBundleVersion.

The build number is the commit count, not a CI run number, because it must be
deterministic from the tag alone and must never go backwards: Sparkle compares
CFBundleVersion to decide whether an update is newer, and commit count only grows along
`main`'s history. Both targets inherit both settings from the project level.

## Building and verifying a Release locally

```sh
eval "$(scripts/release/release-version.sh v1.2.3)"
xcodebuild -project Yellowhammer.xcodeproj -scheme Yellowhammer -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages \
  MARKETING_VERSION="$MARKETING_VERSION" CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION" \
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" CLANG_COVERAGE_MAPPING=NO build
scripts/release/sign-sparkle.sh build/DerivedData/Build/Products/Release/Yellowhammer.app
scripts/release/verify-release-build.sh build/DerivedData/Build/Products/Release/Yellowhammer.app \
  "$MARKETING_VERSION" "$CURRENT_PROJECT_VERSION" "$SPARKLE_PUBLIC_ED_KEY"
```

This needs the Developer ID Application identity in your keychain — see
[doc/signing-identity.md](signing-identity.md) for installing it on a release machine — and a
provisioned update channel key (`SPARKLE_PUBLIC_ED_KEY` in your environment) — see
[doc/update-channel.md](update-channel.md).

## CI

`.github/workflows/release-build.yml` is a reusable workflow: it takes a `tag` input and
runs either via `workflow_call` — invoked by `.github/workflows/release.yml`'s `build`
job immediately after release-please creates a tag and a draft GitHub Release for a
merged release pull request — or via `workflow_dispatch` for a chosen tag, to rebuild an
existing release (e.g. after a failed run). There is no `push: tags` trigger: tags and
releases created with a workflow's own `GITHUB_TOKEN` do not fire other workflow runs,
so pushing a tag would never start this workflow. See
[doc/release-checklist.md](release-checklist.md) for the release-PR flow end to end.

The job signs with the same CI secrets as `release-signing.yml`, builds Release, verifies
it, notarizes and staples it, and packages a signed and notarized DMG — see
[Packaging and distribution](#packaging-and-distribution-p164) below — then publishes to
the release release-please already created:

1. Uploads the DMG, the notarized zip and `SHA256SUMS` to the existing (draft) release
   with `gh release upload --clobber`.
2. Sets the release body to release-please's own changelog (already on the release)
   followed by a "Spec" section from `scripts/release/release-notes.sh`, appended below a
   `<!-- spec-notes -->` marker — `gh release edit --notes-file`.
3. Un-drafts the release (`gh release edit --draft=false`), which is what actually
   publishes it to `releases/latest` and the update feed.

Re-running for the same tag (`workflow_dispatch`) is idempotent: the upload step
`--clobber`s existing assets and the notes step rewrites the body, so re-running never
tries to create a second release for the same tag.

## Notarization, stapling and verification (P16.3)

After the Release build is signed and verified, `scripts/release/notarize.sh
<path-to-app> <output-dir>`:

1. Zips the `.app` (notarytool cannot take a bare bundle) and submits it with
   `xcrun notarytool submit --wait`, saving the full JSON response to
   `<output-dir>/notarization-submit.json`. The submission `id` and `status` are parsed
   from that JSON — the command's own exit code is not trusted, since a rejected or
   timed-out submission still exits informatively.
2. Fetches `xcrun notarytool log` for that submission into
   `<output-dir>/notarization-log.json` **before** deciding pass or fail, on every
   outcome — including `Invalid`/`Rejected` — so the log is always available to explain a
   rejection. A failure to fetch the log is a warning, not a masked pass.
3. Fails the job unless the submission status is exactly `Accepted`, printing any
   `issues` from the log.
4. Staples the notarization ticket to the `.app` with `xcrun stapler staple`, then runs
   `scripts/release/verify-notarized.sh <path-to-app>`, which must pass all three checks:
   - `codesign --verify --deep --strict` — the bundle and its contents verify.
   - `spctl --assess --type execute` — Gatekeeper accepts it, and specifically
     reports `source=Notarized Developer ID` (not merely Developer ID signed).
   - `xcrun stapler validate` — the ticket is stapled.
5. Re-zips the stapled, verified `.app` as the distributable
   (`NOTARIZED_ZIP_NAME`, default `<AppName>.zip`) — the pre-notarization submission zip
   has no ticket and is never the artifact.

`verify-notarized.sh` is a separate script so later steps (P16.4 packaging, a P16.6
installed-product check) can re-run the same three checks against a downloaded copy.

In CI, `NOTARY_API_KEY_PATH` (written by `setup-signing.sh` to `$GITHUB_ENV`) plus the
`NOTARY_API_KEY_ID`/`NOTARY_API_ISSUER_ID` secrets authenticate notarytool. Locally, it
authenticates with the `notarytool` keychain profile named by `NOTARY_PROFILE` (default
`yellowhammer-notary`) — provision it once with:

```sh
xcrun notarytool store-credentials yellowhammer-notary \
  --apple-id <apple-id> --team-id "$DEVELOPER_TEAM_ID" --password <app-specific-password>
```

or the API-key form documented in `xcrun notarytool store-credentials --help`. Then run:

```sh
scripts/release/notarize.sh build/DerivedData/Build/Products/Release/Yellowhammer.app \
  build/notarization
```

A rejection fails the script; `build/notarization/notarization-log.json` is the file to
read — its `issues` array names what Apple objected to.

## Packaging and distribution (P16.4)

After notarization, `scripts/release/package-dmg.sh <path-to-app> <out-dir> <dmg-basename>
[extra-file-in-out-dir]...` builds the distributable disk image:

1. Stages the `.app` plus an `Applications -> /Applications` symlink in a scratch
   directory, then builds a compressed, APFS-formatted DMG with `hdiutil create`.
2. **Signs the DMG itself**, separately from the app inside it, with the Developer ID
   Application identity (`SIGNING_IDENTITY`, falling back to `"Developer ID
   Application"`) and a secure timestamp. This matters because Gatekeeper's assessment
   of a double-clicked disk image looks at the DMG's own signature, not just the app it
   contains — an unsigned DMG holding a notarized app still trips a warning.
3. Submits the signed DMG for notarization and staples the ticket, using the same
   `xcrun notarytool` auth convention as `notarize.sh` (`NOTARY_API_KEY_PATH` in CI,
   the `NOTARY_PROFILE` keychain profile locally). The full submit response and log land
   in `<out-dir>/dmg-notarization-submit.json` and `<out-dir>/dmg-notarization-log.json`.
4. Verifies the result the same way `verify-notarized.sh` verifies the app:
   `codesign --verify --strict`, `spctl --assess --type open --context
   context:primary-signature` reporting `source=Notarized Developer ID`, and `xcrun
   stapler validate`.
5. Writes `<out-dir>/SHA256SUMS` with `shasum -a 256` over the DMG and any extra files
   passed in (the notarized zip, when given as a fourth argument), using bare file names
   so `shasum -a 256 -c SHA256SUMS` verifies correctly when run from the folder holding
   the downloaded files.

`scripts/release/release-notes.sh <tag> [<previous-tag>]` derives release notes from the
`Spec: <epic>/<story> @ <sha>` trailer lines (see CLAUDE.md) on every commit between the
previous release and this one — `<previous-tag>` defaults to the most recent `v*` tag
reachable from `<tag>^`, or the root commit if there is none. It prints Markdown naming
the spec commit the release was built against (the newest cited spec sha), the sorted,
de-duplicated list of story IDs touched, and — when more than one distinct spec sha was
cited — the full list of those shas, plus a reminder to verify the download against
`SHA256SUMS`.

In CI, `.github/workflows/release-build.yml` runs both after notarizing and stapling the
app: it packages the DMG into `build/artifacts` (alongside the notarized zip, so both
land in `SHA256SUMS`), writes the "Spec" section with `scripts/release/release-notes.sh`,
and then updates the release release-please already created for the tag — see
[CI](#ci) above for the upload/notes/un-draft sequence. The job never creates the release
itself; release-please owns that. It grants itself `contents: write` to upload assets and
edit the release; the workflow's top-level permission stays `contents: read`.

### Where the release is hosted

Releases are published to this repository's own GitHub Releases
(`summerhammer/yellowhammer`). The repository is currently private, so downloading a
release — DMG, zip or `SHA256SUMS` — requires access to the repository; there is no
separate public distribution point yet.

### Manual acceptance check

The roadmap's P16.4 done-criterion is verified by hand, on a clean Apple Silicon Mac:

1. Download the DMG (and `SHA256SUMS`) from the GitHub release.
2. `shasum -a 256 -c SHA256SUMS` in the download folder — the DMG line must report `OK`.
3. Open the DMG, drag `Yellowhammer.app` to `/Applications`, and launch it — Gatekeeper
   must not show a warning (neither on opening the DMG nor launching the app).
4. `spctl --assess -v /Applications/Yellowhammer.app` must report `source=Notarized
   Developer ID`.
