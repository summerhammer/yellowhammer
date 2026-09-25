# Release checklist

This file starts the release checklist named by roadmap item P16.7, which will add the remaining
items (CI green, the probe drift check, notarization, installed-product verification, release
notes, spec conflict re-checks). Only the rehearsal suite step (P15.4) is here so far.

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
