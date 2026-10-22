import Domain
import Foundation

/// The `claude` CLI Adapter (spec `routing/add-an-agent-cli`; probe evidence:
/// `attachments/investigations/2026-09-13-feasibility-probes/cli-probe.md`).
///
/// Forces structured output with `--json-schema`, reads it back from the `structured_output` field of the
/// `result` events in `--output-format stream-json`'s stdout, and resumes a session with
/// `--resume <session_id>` (a fresh run instead picks its own id with `--session-id <uuid>`, so the
/// id survives even a run whose stdout ``collect(end:dispatch:)`` cannot parse).
///
/// `json` mode prints only the final result of an invocation, so a pass that queued a follow-up turn lost
/// its StructuredOutput (issue #643); `stream-json` keeps every turn's result, and the reader takes the last
/// good one.
public struct ClaudeCodeAdapter: CLIAdapter {
    public let cli = "claude"
    /// "3": the argv gained `--settings <run directory>/claude-settings.json` (issue #546). "4": stdout is
    /// `stream-json`, background tasks are disabled and follow-up tools are denied so a pass ends at its
    /// StructuredOutput (issue #643).
    public let adapterVersion = "4"
    /// `claude --help`'s `--effort` choices.
    public let supportedEfforts = ["low", "medium", "high", "xhigh", "max"]

    public init() {}

    public func launch(for dispatch: CLIDispatch) throws(CLIAdapterError) -> AgentCLILaunch {
        try validateRoute(dispatch)
        let resultFile = try prepareRunDirectory(dispatch)
        let stdoutFile = dispatch.runDirectory.appendingPathComponent(Self.stdoutFileName)
        setAsideCapture(stdoutFile)
        let sessionIDFile = dispatch.runDirectory.appendingPathComponent(Self.sessionIDFileName)

        var arguments = [
            "-p", dispatch.instruction,
            "--output-format", "stream-json", "--verbose",
            "--json-schema", CLIOutputSchema.strict(for: dispatch.pass),
            "--model", dispatch.route.model,
            "--effort", dispatch.route.effort
        ]

        if let resume = dispatch.resume {
            arguments += ["--resume", resume.rawValue]
        } else {
            let freshSessionID = UUID().uuidString.lowercased()
            // Recorded so `collect(end:dispatch:)` can still name the session used even when stdout
            // is empty or unparsable (e.g. the process was killed before it could print anything).
            try? freshSessionID.write(to: sessionIDFile, atomically: true, encoding: .utf8)
            arguments += ["--session-id", freshSessionID]
        }

        arguments += ["--settings", try Self.writeSettings(for: dispatch)]

        let permissions = Self.permissions(for: dispatch.pass)
        arguments += [
            "--permission-mode", permissions.mode,
            "--allowedTools", permissions.allowed,
            "--disallowedTools", permissions.disallowed
        ]
        for directory in dispatch.additionalReadableDirectories {
            arguments += ["--add-dir", directory]
        }
        for directory in dispatch.additionalWritableDirectories {
            arguments += ["--add-dir", directory]
        }

        // Merged, not replaced: `posix_spawn` receives this environment verbatim.
        var environment = dispatch.environment
        environment["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"] = "1"

        return AgentCLILaunch(
            executable: dispatch.executable,
            arguments: arguments,
            environment: environment,
            worktreePath: dispatch.worktreePath,
            resultFile: resultFile,
            pass: dispatch.pass,
            timeout: dispatch.timeout,
            outputLog: dispatch.runDirectory.appendingPathComponent("stderr.log"),
            standardOutput: stdoutFile
        )
    }

    public func collect(end: RunEnd, dispatch: CLIDispatch) -> CLISession? {
        let sessionIDFile = dispatch.runDirectory.appendingPathComponent(Self.sessionIDFileName)
        let launchedSessionID = (try? String(contentsOf: sessionIDFile, encoding: .utf8))
            .map { CLISession(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let fallback = dispatch.resume ?? launchedSessionID

        let stdoutFile = dispatch.runDirectory.appendingPathComponent(Self.stdoutFileName)
        guard let data = try? Data(contentsOf: stdoutFile) else { return fallback }
        let results = Self.resultEvents(in: data)
        guard let last = results.last else { return fallback }

        let session = (last["session_id"] as? String).map(CLISession.init(rawValue:)) ?? fallback

        // The last good structured result wins: a text-only result after it is a follow-up turn, not a
        // second answer. Only this invocation's capture is read; a previous Round's is set aside at launch.
        let good = results.last(where: { result in
            !(result["is_error"] as? Bool ?? false) && result["structured_output"] is [String: Any]
        })
        if let structuredOutput = good?["structured_output"] as? [String: Any] {
            let resultFile = dispatch.runDirectory.appendingPathComponent("result.json")
            // The forced schema declares optional fields nullable; the Domain schema wants them absent.
            let members = structuredOutput.filter { !($0.value is NSNull) }
            if let data = try? JSONSerialization.data(withJSONObject: members, options: [.sortedKeys]) {
                try? data.write(to: resultFile)
            }
        }
        return session
    }

    // MARK: - Permissions

    public func usageLimit(for dispatch: CLIDispatch) -> RunOutcome? {
        let stdout = dispatch.runDirectory.appendingPathComponent(Self.stdoutFileName)
        guard let data = try? Data(contentsOf: stdout), let last = Self.resultEvents(in: data).last,
              last["is_error"] as? Bool == true,
              last["api_error"] as? String == "usage_limit_reached" else { return nil }
        return .usageLimited(resetHint: last["result"] as? String)
    }

    private struct Permissions {
        let mode: String
        let allowed: String
        let disallowed: String
    }

    /// The tools that queue a follow-up turn or start background work. A pass must end when it emits its
    /// StructuredOutput: a `ScheduleWakeup` or a background task makes claude take more turns after it, and
    /// the final text-only result then replaced the structured one in `json` mode (issue #643). Denied for
    /// every pass, the worker included.
    private static let followUpTools = ["ScheduleWakeup", "CronCreate", "Monitor", "Workflow", "RemoteTrigger"]

    /// Per pass (spec `routing/add-an-agent-cli`): the worker edits and commits unattended under
    /// `acceptEdits`; the architect and reviewer never touch files, so they run under `dontAsk` with
    /// `Edit`/`Write`/`NotebookEdit` explicitly denied. Every pass denies ``followUpTools``.
    ///
    /// Containment (issue #546) is the `--settings` file ``settingsJSON(for:protectedDirectories:)``
    /// writes: the read-only passes run in a sandbox that denies Yellowhammer's configuration directory
    /// and the Keychains and refuses the vendor APIs; the worker is never sandboxed by Yellowhammer
    /// (issue #553, ruled 2026-10-17; see `doc/agent-pass-containment.md`) and gets permission deny rules only.
    private static func permissions(for pass: RunPass) -> Permissions {
        switch pass {
        case .worker:
            Permissions(
                mode: "acceptEdits",
                allowed: "Bash Edit Write Read Glob Grep",
                disallowed: followUpTools.joined(separator: " ")
            )
        case .architect, .reviewer, .selection, .breakdown, .verifier:
            Permissions(
                mode: "dontAsk",
                allowed: "Bash Read Glob Grep",
                disallowed: (["Edit", "Write", "NotebookEdit"] + followUpTools).joined(separator: " ")
            )
        }
    }

    // MARK: - Containment settings

    /// Vendor API domains a read-only pass's sandbox refuses (issue #546): Yellowhammer alone writes the
    /// board and opens pull requests.
    private static let deniedVendorDomains = [
        "linear.app", "*.linear.app", "github.com", "*.github.com", "api.github.com"
    ]

    /// The `--settings` file for one pass, serialized with sorted keys so it is deterministic.
    ///
    /// Read-only passes run in claude's sandbox, failing closed (`failIfUnavailable`) and never escaping
    /// it (`allowUnsandboxedCommands: false`): `denyRead` covers the protected directories, the network
    /// allowlist is strict with the vendor APIs denied, and `WebFetch`/`WebSearch` and `Read` of the
    /// protected directories are denied as permissions too. Measured live (claude 2.1.302): the Keychain
    /// read exits 44 without a prompt, the configuration directory is "Operation not permitted", and the
    /// vendor APIs are refused, while `git` and the model API still work.
    ///
    /// The worker is never sandboxed by Yellowhammer (issue #553, ruled 2026-10-17; see
    /// `doc/agent-pass-containment.md`), and its deny rules are best-effort. SwiftPM runs its own
    /// `sandbox-exec` for package manifests, and a nested Seatbelt fails (`sandbox_apply: Operation not
    /// permitted`), so `swift build` would break under claude's sandbox. Rules on `Read`/`Edit`, on
    /// `security` and on `WebFetch` stop the direct routes, but a model can still reach the same
    /// resources through another interpreter or tool.
    ///
    /// Paths are absolute: an app-spawned `yh` can run with an empty environment, and in a permission
    /// rule an absolute path is written with a leading `//`.
    static func settingsJSON(for pass: RunPass, protectedDirectories: [String]) throws -> Data {
        let readRules = protectedDirectories.map { "Read(/\($0)/**)" }
        var settings: [String: Any]
        switch pass {
        case .worker:
            let editRules = protectedDirectories.map { "Edit(/\($0)/**)" }
            settings = [
                "permissions": [
                    "deny": readRules + editRules + [
                        "Bash(security *)", "Bash(/usr/bin/security *)",
                        "WebFetch(domain:linear.app)", "WebFetch(domain:api.linear.app)",
                        "WebFetch(domain:api.github.com)"
                    ]
                ]
            ]
        case .architect, .reviewer, .selection, .breakdown, .verifier:
            settings = [
                "sandbox": [
                    "enabled": true,
                    "failIfUnavailable": true,
                    "autoAllowBashIfSandboxed": true,
                    "allowUnsandboxedCommands": false,
                    "filesystem": ["denyRead": protectedDirectories],
                    "network": ["strictAllowlist": true, "deniedDomains": deniedVendorDomains]
                ],
                "permissions": ["deny": ["WebFetch", "WebSearch"] + readRules]
            ]
        }
        return try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .prettyPrinted])
    }

    // MARK: - Stdout parsing

    private static let settingsFileName = "claude-settings.json"
    private static let stdoutFileName = "stdout.json"
    private static let sessionIDFileName = ".session-id"

    /// Writes this pass's `--settings` file into the run directory and returns its path.
    private static func writeSettings(for dispatch: CLIDispatch) throws(CLIAdapterError) -> String {
        let settingsFile = dispatch.runDirectory.appendingPathComponent(settingsFileName)
        do {
            let settings = try settingsJSON(for: dispatch.pass, protectedDirectories: dispatch.protectedDirectories)
            try settings.write(to: settingsFile, options: .atomic)
        } catch {
            throw .runDirectoryUnwritable("\(error)")
        }
        return settingsFile.path(percentEncoded: false)
    }

    /// The `"type":"result"` events of a `stream-json` capture, in order: one per turn of the invocation.
    /// The capture is JSON Lines and can be megabytes of tool output, so each line is first checked for
    /// the literal `"result"` (every result event has it) and only the survivors are parsed. The capture is
    /// split on newline bytes before any decoding: a killed process can leave a torn multi-byte UTF-8
    /// sequence on its last line, and decoding the whole capture would then hide every earlier event. A
    /// line that does not decode or parse is skipped and never hides the lines around it.
    static func resultEvents(in data: Data) -> [[String: Any]] {
        var results: [[String: Any]] = []
        for bytes in data.split(separator: 0x0A) {
            guard let line = String(data: Data(bytes), encoding: .utf8), line.contains("\"result\"") else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "result" else { continue }
            results.append(object)
        }
        return results
    }
}
