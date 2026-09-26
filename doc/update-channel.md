# Update channel (P16.5)

Yellowhammer updates itself with Sparkle 2, gated so it can never corrupt a live Act.

## What G-14 requires

The spec's Decision Gates Ruling (`../yellowhammer-spec/docs/requirements/vision/risks.md`,
`#decision-gates-ruling-2026-09-15`, G-14) and `../yellowhammer-spec/docs/tech/stack.md` →
Distribution are binding here — read the ruling itself rather than trusting a summary. In
outline, updates must be: Sparkle 2, EdDSA-signed, checked only while the app is open, never
installed silently, and refused while any Project's Journal holds a live Lease (because
`launchd` runs `yh` from inside the app bundle, so replacing the bundle under a live Lease would
corrupt whatever Act holds it). Nothing resident is added: no background check, no timer, no
login item.

## How the app enforces each clause

| Clause | Enforced by |
|---|---|
| Sparkle 2, EdDSA-signed | `Sparkle` SPM package (`Yellowhammer.xcodeproj`); `SUPublicEDKey` in `Support/Yellowhammer-Info.plist` |
| Checked only while the app is open | `SPUStandardUpdaterController` is constructed in `YellowhammerApp.init()`, never in the headless launches (`AppLaunch.swift` routes `yh --post-notification` and `yh setup` to `HeadlessPost`/`HeadlessPermissionRequest` before `YellowhammerApp.main()` ever runs) |
| Never installed silently | `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate`, `SUAllowsAutomaticUpdates` are all `NO` in `Support/Yellowhammer-Info.plist`; the only way to start a check is the "Check for Updates…" command (`YellowhammerApp.swift`) |
| Refused while a live Lease is held | `Journal/JournalStore+LiveLease.swift` (`holdsLiveLease(now:)`, reading both the Card-scoped `lease` table and the Act-scoped `act_lease` table) backs `LiveLeaseScan` (`Yellowhammer/Updater.swift`), which `UpdaterDelegate` consults in `updater(_:shouldProceedWithUpdate:updateCheck:)`, before an update is shown or downloaded — see the gap below for what this does and does not close |
| Nothing resident | No `MenuBarExtra`, no timer, no scheduled check; Sparkle's own periodic-check machinery is disabled by the three `SU*` flags above |

A refusal names every Project involved and, for a live Lease, reads "Yellowhammer can't update
while an Act is running for `<Project>`. Try again when it finishes." A Journal (or the whole
Project configuration) that fails to open for a reason other than not existing yet is refused
too — fail closed, named — rather than treated as having no Lease.

### Known, unclosed gap: a Lease claimed after the check is not caught

`shouldProceedWithUpdate` is the only Sparkle 2 delegate hook this app can refuse an update
through, and it only gates the *download*. Verified against Sparkle's own source
(`Autoupdate/AppInstaller.m`): once that hook passes, Sparkle downloads, verifies and extracts
the update automatically in the background ("stage 1"), independent of whether the Operator ever
clicks "Install and Relaunch". A second-looking hook,
`shouldPostponeRelaunchForUpdate:untilInvokingBlock:`, was tried and removed: once stage 1 has
completed, quitting the host app for *any* reason makes Sparkle's separate installer process
perform the file swap on its own (`-finishInstallationAfterHostTermination`), regardless of what
that delegate method returns or whether it was ever asked. There is no delegate hook that gates
install itself once the update is downloaded — refusing there would only show a misleading "can't
install" message and then install anyway on the next quit.

The practical consequence: a Lease claimed after a "Check for Updates…" passes and before
Yellowhammer next quits is not caught by anything in this app. Two honest ways to close it, not
yet chosen:

1. Accept the window as-is and rely on the ordinary Operator flow — checks are infrequent and
   user-initiated, and an Act starting in the few minutes between a check and quitting the app is
   an edge case, documented rather than engineered around.
2. Change what "quit" means for Yellowhammer while an update is staged: e.g. warn on quit if a
   Lease is live and an update has been downloaded, or refuse to relaunch the download at all
   until the Operator confirms no Act is running. Either needs product input — it is not a small
   code change, and it touches "the app is a window app" / "no state machine in the app" rulings
   in `CLAUDE.md`.

This gap is called out explicitly rather than papered over with a hook that only appears to
close it.

## Provisioning the signing key (a human does this once, then on rotation)

1. Generate the keypair with Sparkle's own tool (from the resolved package, or download
   Sparkle's release tools separately):

   ```sh
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

   Run it once to create the keypair (stored in this machine's login Keychain) and print the
   public key. Never commit the private key.

2. Export the private key to a throwaway file, upload it as the secret, then delete it — never
   paste the key itself into a shell command or leave it in shell history:

   ```sh
   key_dir="$(mktemp -d)"; key_file="$key_dir/sparkle-private-key"
   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x "$key_file"
   gh secret set SPARKLE_ED_PRIVATE_KEY --repo summerhammer/yellowhammer < "$key_file"
   rm -rf "$key_dir"
   ```

3. Set the public key as a repository **variable** (not a secret — it ships inside the app and
   is not sensitive):

   ```sh
   gh variable set SPARKLE_PUBLIC_ED_KEY --repo summerhammer/yellowhammer --body '<public key>'
   ```

4. `.github/workflows/release-build.yml` passes `SPARKLE_PUBLIC_ED_KEY` into the Release
   `xcodebuild` invocation as a build setting (baked into `Support/Yellowhammer-Info.plist` via
   `$(SPARKLE_PUBLIC_ED_KEY)`), and `scripts/release/appcast.sh` signs the notarized zip with
   `secrets.SPARKLE_ED_PRIVATE_KEY` after packaging, writing `build/artifacts/appcast.xml`.
   `scripts/release/verify-release-build.sh` fails the release job early if the public key is
   empty or the built app's `SUPublicEDKey` doesn't match it, or if any of the three `SU*` flags
   above is not `false`.

### Ownership and rotation

Owned the same way as the Developer ID and notarization credentials — see
[doc/signing-identity.md](signing-identity.md) for the ownership table's conventions; add the
Sparkle key to that table on first provisioning.

**Rotating the key strands installed copies unless one release ships with the new public key
baked in but still signed by the old private key.** A Mac only trusts an appcast item signed
with the private key matching the `SUPublicEDKey` baked into the copy it is running — rotate the
private key and public key together in one release, and every earlier install can no longer
verify anything Sparkle offers it. The safe sequence is a one-release transition:

1. Generate the new keypair. Update the `SPARKLE_PUBLIC_ED_KEY` **variable** to the new public
   key; leave the `SPARKLE_ED_PRIVATE_KEY` **secret** as the old private key for now.
2. Tag and ship this transitional release: the app is built with the new public key baked in
   (so it will trust future new-key releases), but `appcast.sh` still signs it with the old
   private key (so every install still running an old public key can verify and adopt it).
3. Only after that release is out, update `SPARKLE_ED_PRIVATE_KEY` to the new private key.
4. Ship the next release normally — it is both built with and signed by the new key. Any Mac
   that updated to the transitional release (step 2) trusts it; a Mac that misses the
   transitional release and stays further behind cannot verify this or any later release and
   will not auto-offer an update — it needs a manual download of a release built after step 1.

## Known limitation: the repository is private, so the feed is unreachable today

`doc/release-build.md` already notes the repository (`summerhammer/yellowhammer`) is currently
private. `SUFeedURL` is an unauthenticated fetch, so Sparkle's request for
`releases/latest/download/appcast.xml` gets an HTTP 404 while the repository stays private — the
update channel is otherwise fully wired but inert until the repository is made public (or the
feed is moved to a location that does not require authentication).

## Known limitation: only the newest release is offered

`SUFeedURL` points at `.../releases/latest/download/appcast.xml`, so the feed always resolves
to the most recently published GitHub release's single-item appcast (`appcast.sh` writes exactly
one `<item>`, the release it runs for). A Mac on an old version is offered only the latest
version, never a chain of intermediate updates — Sparkle's version comparison still refuses a
downgrade, but there is no delta or staged-upgrade path. This is accepted as a known limitation,
not a defect: revisit only if a future release makes a breaking migration that an old build
cannot skip straight to.
