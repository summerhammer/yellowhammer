# Release checklist

This file starts the release checklist named by roadmap item P16.7, which will add the remaining
items (CI green, the probe drift check, notarization, release notes, spec conflict re-checks).
The rehearsal suite step (P15.4), update channel provisioning (P16.5) and installed-product
verification (P16.6) are here so far.

## Rehearsal suite green on the release commit

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

4. Attach the evidence directory to the release (e.g. zip it and attach as a release asset):
   `suite.log`, `journals/` (a Journal snapshot per scenario step), `night-cards.md` (every Night
   Card the run created, linked), and `verdict.json`.

## Update channel provisioning (P16.5)

Before the first tagged release, and on every Sparkle key rotation, confirm the repository
variable `SPARKLE_PUBLIC_ED_KEY` and secret `SPARKLE_ED_PRIVATE_KEY` are set — see
[doc/update-channel.md](update-channel.md). `scripts/release/verify-release-build.sh` fails the
release job if the public key is empty or missing from the built app.

## Installed-product verification (P16.6)

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
