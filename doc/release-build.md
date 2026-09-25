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
`release-signing.yml`, builds Release, verifies it, and uploads the zipped `.app`.
Notarization/stapling is P16.3, packaging is P16.4.
