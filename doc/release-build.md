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
  MARKETING_VERSION="$MARKETING_VERSION" CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION" build
scripts/release/verify-release-build.sh build/DerivedData/Build/Products/Release/Yellowhammer.app \
  "$MARKETING_VERSION" "$CURRENT_PROJECT_VERSION"
```

This needs the Developer ID Application identity in your keychain — see
[doc/signing-identity.md](signing-identity.md) for installing it on a release machine.

## CI

`.github/workflows/release-build.yml` runs on every `v*` tag push (and on
`workflow_dispatch` for a chosen tag), signs with the same CI secrets as
`release-signing.yml`, builds Release, verifies it, notarizes and staples it, and
uploads the zipped `.app`. Packaging (DMG, checksums, hosting) is P16.4.

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
