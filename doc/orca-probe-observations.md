# Orca observations in `yh probe`

`yh probe <cli> --keep` records six informational Orca observations in the Ledger alongside
the existing findings. `yh probe --all` includes Claude (`claude`), Codex (`codex`) and
Antigravity (`agy`). The observations do not change route eligibility, drift, naming flags,
or the adapters' resume checks.

The report prints `yes`, `no` or `unconfirmed`, with evidence or a reason. An unavailable
observation does not prove that Orca lacks a capability. In particular, full-text search
can be disabled while the Agent Session History panel still lists sessions.

| Observation | Evidence |
| --- | --- |
| Recognised in a tab | `worktree ps` matches the Probe's exact Worktree, CLI, unique prompt token and requested `conversationName`. |
| Listed in History | Orca search returns the direct session's exact id, CLI and cwd, with its source present. Incomplete or unavailable search is unconfirmed. |
| Session name shown | The matching History row's actual title equals the requested pass name. An adapter without a naming flag keeps its existing behaviour. |
| Foreign-turn marker | Claude user records carry `entrypoint=sdk-cli`; Codex's matching rollout metadata carries `source=exec`. Missing evidence is unconfirmed. Antigravity has no verified marker reader yet. |
| Tab-close containment | Closing the holding pass's tab produces wrapper SIGTERM evidence, with no engine cancellation signal, and leaves no observed CLI/tool descendants alive. |
| Localhost hook traffic | The Probe's prompt and hold-tool input appear in Orca, and the installed hook script posts to `127.0.0.1`. The report labels the transport as inferred from the script, without claiming a packet capture. |

The tab-close pass uses a separate disposable Orca Worktree of the Probe's scratch repository.
It closes its tab and releases the Worktree and registration on success, failure and cancellation.
Cleanup errors are reported. The existing SIGTERM/SIGKILL containment passes still exercise
both direct spawn and the Orca wrapper host.

The scratch directory is retained if any Orca observation is unconfirmed or fails. It contains
the tab launcher's captures and wrapper records; unrelated Orca sessions are never retained.
The Probe does not enable Orca's search index, edit agent hooks, or change agent configuration.

Fixture tests validate observation parsing, scoping, cleanup, reporting and Ledger persistence.
They do not establish compatibility with a particular installed agent version. Run the live
Probe for each CLI to collect that evidence; each run dispatches real agent passes and may use
the account's allowance.
