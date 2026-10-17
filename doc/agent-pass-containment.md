# Agent pass containment

What an agent CLI pass can reach on this Mac, what Yellowhammer decided to do about it, and what
to do when a macOS dialog appears. For the Operator and future maintainers. State as of
[PR #578](https://github.com/summerhammer/yellowhammer/pull/578).

## What a pass can reach

Facts marked "measured" were measured 2026-10-17/18.

| CLI and pass | Containment | Keychain | Yellowhammer state | Vendor APIs |
| --- | --- | --- | --- | --- |
| claude, read-only (architect, reviewer, selection, breakdown, verifier) | claude's own sandbox, from a `--settings` file the adapter writes (`ClaudeCodeAdapter.settingsJSON`). Fails closed, never runs unsandboxed. `denyRead` on the configuration directory and `~/Library/Keychains`; `WebFetch` and `WebSearch` denied. Measured with claude 2.1.302 ([PR #558](https://github.com/summerhammer/yellowhammer/pull/558)). | blocked | blocked | blocked (strict network allowlist denies `linear.app` and `github.com`) |
| claude, worker | Not sandboxed. Permission deny rules only: `Read`/`Edit` of the protected directories, `Bash(security *)`, `WebFetch` to Linear and GitHub. A model can still reach them through another interpreter. | deny rules only | deny rules only | `WebFetch` denied, shell not blocked |
| codex, read-only | codex's `read-only` Seatbelt blocks the Keychain and the network. Since [PR #575](https://github.com/summerhammer/yellowhammer/pull/575) the adapter uses a permissions profile (`default_permissions="yellowhammer"`, `extends ":read-only"`, each protected directory `"deny"`) instead of `--sandbox read-only`. Measured with codex-cli 0.163.0: configuration directory "Operation not permitted", Worktree readable, fresh and resumed. | blocked | blocked | blocked |
| codex, worker | `--sandbox workspace-write`, unchanged. | blocked | configuration directory readable | network blocked |
| agy, every pass | `--dangerously-skip-permissions`, no sandbox (its sandbox breaks `.git` and linked Worktrees). The Probe reports `failed: keychain readable, config readable, linear reachable` (agy 1.4.1). | open | open | open |

Every pass's prompt also carries the `## Boundaries` section (`Domain/PassBoundaries.swift`):
Yellowhammer's state, the Keychain and vendor APIs are off limits, and what the pass needs is in
the instruction. This is a request, not enforcement.

## Ruling: the worker is never sandboxed by Yellowhammer

Issue [#553](https://github.com/summerhammer/yellowhammer/issues/553), ruled 2026-10-17.

Under claude's sandbox `swift build` fails with `sandbox-exec: sandbox_apply: Operation not
permitted`. SwiftPM compiles `Package.swift` inside its own `sandbox-exec`, and macOS Seatbelt
refuses a nested sandbox. `xcodebuild` script phases have the same shape.

Three options were considered and rejected:

- **(a) Sandbox the worker, with `excludedCommands` for `swift` and `xcodebuild`.** Those commands
  then run unsandboxed, and the hole reopens through the tools the worker uses most.
- **(b) Tell the worker to use `swift build --disable-sandbox`** (or the `xcodebuild` equivalent).
  That is a per-language workaround in a product that must run arbitrary repositories, and it does
  not cover script phases.
- **(c) An outer `sandbox-exec` profile of Yellowhammer's own.** Same nesting problem, and it
  would cut the CLI off from its own credential.

So the worker keeps its deny rules and the prompt boundary. What matters is protected elsewhere:
read-only passes are sandboxed where the CLI offers it, the Keychain hazard is handled below, and
a prompt now ends the pass.

## Keychain direction

Issue [#554](https://github.com/summerhammer/yellowhammer/issues/554), decided 2026-10-17.

Yellowhammer keeps its legacy login-Keychain items (`KeychainCredentialStore`, service
`dev.yellowhammer`, ACL trusting `yh`). It does not migrate to the data-protection keychain,
because:

- It needs a `keychain-access-groups` entitlement on the embedded `yh`. For Developer ID that most
  likely means a provisioning profile, which a bare command-line tool cannot carry.
- Debug `yh` and `swift test` lose access (-34018) until every test goes through an in-memory store.
- Existing items need a one-time migration.

The hazard is closed instead by prompt detection (next section), the guidance "answer Deny", and a
planned `yh doctor` finding for an item whose access or partition list was widened
([#573](https://github.com/summerhammer/yellowhammer/issues/573)).

Preconditions to revisit data protection: prove an embedded Developer ID `yh` gets the access
group without a profile, or embed one; add a `CredentialStore` seam with an in-memory fake; and
write a read-old, write-new, delete-old migration on first engine open.

## A macOS permission prompt ends the pass

Issue [#555](https://github.com/summerhammer/yellowhammer/issues/555), [PR #578](https://github.com/summerhammer/yellowhammer/pull/578).

For the life of each pass the engine watches the unified log for `securityd`'s
`displaying keychain prompt for <path>(<pid>)` line. When the pid is the agent CLI or one of its
descendants, the pass ends at once. It is classified Crashed-Unknown with
`stopped by the engine: a macOS permission prompt blocked the pass: …`. The Attempt is consumed, no
Route is excluded, and a final Attempt Blocks under `engine fault`. This is an interim
classification; the spec question is
[yellowhammer-spec#114](https://github.com/summerhammer/yellowhammer-spec/issues/114).

Limits:

- Only Keychain prompts are detected. TCC privacy prompts are not detected yet.
- **Ending the pass does not dismiss the dialog.** Measured 2026-10-18 on macOS 27: the
  SecurityAgent window stays until a human answers it.
- A `log stream` watch can outlive a SIGKILLed `yh`
  ([#579](https://github.com/summerhammer/yellowhammer/issues/579)).

## What the Probe measures

The fifth finding, state containment ([PR #575](https://github.com/summerhammer/yellowhammer/pull/575)),
runs one architect pass against three things: a throwaway `dev.yellowhammer.probe` Keychain item
(created with `-A`, so a leak never raises a dialog, and deleted afterwards), the configuration
directory, and `api.linear.app`. It is `passed` only when all three are blocked. The result is
recorded in the Ledger and shown in Settings; it never gates routing. The worker shape is not
measured. `yh probe codex` needs `--model` and `--effort` on a ChatGPT-account codex
([#577](https://github.com/summerhammer/yellowhammer/issues/577)).

Risk R24 in the spec (`docs/requirements/vision/risks.md`) is the background for this area.

## Operator guidance

- If a dialog says "security wants to use your confidential information stored in
  dev.yellowhammer", or a privacy prompt names Yellowhammer.app, answer **Deny** / **Don't Allow**.
  Never Always Allow.
- A stale dialog left over from a Night is the same: Deny.
- If Always Allow was clicked, delete the item in Keychain Access and reconnect. The recovery
  steps are in issue [#546](https://github.com/summerhammer/yellowhammer/issues/546).
- Keep Journal backups outside `~/.config/yellowhammer`.
