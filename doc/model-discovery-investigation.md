# Agent CLI model discovery

Issue #376 investigation. Each settings request starts one bounded model-list operation for the selected
CLI. Discovery does not start a conversation or agent task. The returned display label is shown in the
Picker; the vendor model identifier is stored in the Route.

## Vendor mechanisms

| CLI | Mechanism | Result and limits |
| --- | --- | --- |
| Claude Code (`claude`) | Start the installed CLI with `--print --input-format stream-json --output-format stream-json --verbose --safe-mode --strict-mcp-config --mcp-config '{"mcpServers":{}}' --no-session-persistence`; keep stdin open after sending only a `control_request` with `subtype: initialize`; read its `control_response` model list; then terminate. | Uses the Agent SDK initialization model list, including vendor `value` identifiers and `displayName` labels. No user frame is sent. Safe mode retains authentication and managed model policy; managed settings can still apply. The request has an eight-second timeout and the whole process has a combined 512 KiB stdout/stderr budget. The documented protocol and installed SDK's `Query.supportedModels()` implementation were checked against Claude Code 2.1.292. See [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference) and [Agent SDK TypeScript docs](https://platform.claude.com/docs/en/agent-sdk/typescript). |
| Codex (`codex`) | Start `codex app-server`; send JSON-RPC `initialize`, wait for its response, send `initialized`, then send `model/list` requests with `includeHidden: false` and `limit: 100`. Follow each `nextCursor` until the list is complete. | Stores the response `model` field, not the response's opaque `id`, and omits hidden entries. Pagination is limited to 100 pages, within the same eight-second and combined 512 KiB process budget. It sends no `thread/start` or `turn/start`. Verified against Codex CLI 0.160.1. See [Codex app-server protocol](https://github.com/openai/codex/tree/main/codex-rs/app-server-protocol). |
| Antigravity (`agy`) | Run the installed standalone CLI as `agy models`. | Parses each tab-separated identifier and display label row. The editor-bundled launcher with the same name is rejected by executable discovery. Verified against `agy` 1.3.1. See [Antigravity CLI documentation](https://antigravity.google/docs/cli/headless). |

All calls have an eight-second process timeout and a combined 512 KiB stdout/stderr limit (a missing
executable's login-shell PATH lookup has its own five-second limit). The child runs in a fresh temporary
working directory with owner-only permissions, and in its own process group. Cancellation and timeout
terminate and reap the short-lived process and remaining children in that process group. Results live only in the
visible form state so its Pickers and Save validation use the same response; they are discarded with the
form, never persisted, and are replaced by an explicit Refresh. There is no app-lifetime cache, watcher,
or timer. When discovery is empty or fails, the editor says so and leaves any existing model identifier
untouched. Save preserves an unchanged configured CLI/model pair, while any new or changed pair requires
a discovered identifier. New Routes start without a model. Discovery never fills an empty Route with a
guessed or historical model name.

On 2026-10-07, the Swift implementation was smoke-tested against installed CLIs from a neutral temporary
working directory: Claude Code returned 12 choices in 1.18 seconds, Codex returned 7 in 0.83 seconds, and
`agy` returned 18 in 1.88 seconds. These vendor-reported choices reflect the installed CLI and its account
context; they do not guarantee that a model can be used for a particular task or that the Probe will accept
it.

## Maintaining and manually checking

When a vendor changes its command or protocol, update `Config/CLIDiscovery/AgentModelDiscovery.swift`,
`ModelDiscoveryProtocol.swift`, and `ModelDiscoveryProcess.swift`,
capture a fixture from the non-task discovery response, and add/update the corresponding parser test.
Before release, manually check the documented command against an installed CLI in an empty temporary
working directory. Confirm its output includes identifiers and labels, and inspect the arguments and
input to confirm no prompt, task, thread, or turn start is sent. Check CLI version and documentation URL
in this file when the protocol changes. Never use an inferred alias list as an account-verified result.
