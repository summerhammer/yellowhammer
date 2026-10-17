import Domain
import Foundation

/// The `claude` CLI Adapter (spec `routing/add-an-agent-cli`; probe evidence:
/// `attachments/investigations/2026-09-13-feasibility-probes/cli-probe.md`).
///
/// Forces structured output with `--json-schema`, reads it back from the top-level
/// `structured_output` field of `--output-format json`'s stdout, and resumes a session with
/// `--resume <session_id>` (a fresh run instead picks its own id with `--session-id <uuid>`, so the
/// id survives even a run whose stdout ``collect(end:dispatch:)`` cannot parse).
public struct ClaudeCodeAdapter: CLIAdapter {
    public let cli = "claude"
    /// "3": the argv gained `--settings <run directory>/claude-settings.json` (issue #546).
    public let adapterVersion = "3"
    /// `claude --help`'s `--effort` choices.
    public let supportedEfforts = ["low", "medium", "high", "xhigh", "max"]

    public init() {}

    public func launch(for dispatch: CLIDispatch) throws(CLIAdapterError) -> AgentCLILaunch {
        try validateRoute(dispatch)
        let resultFile = try prepareRunDirectory(dispatch)
        let sessionIDFile = dispatch.runDirectory.appendingPathComponent(Self.sessionIDFileName)

        var arguments = [
            "-p", dispatch.instruction,
            "--output-format", "json",
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

        let settingsFile = dispatch.runDirectory.appendingPathComponent(Self.settingsFileName)
        do {
            let settings = try Self.settingsJSON(
                for: dispatch.pass, protectedDirectories: dispatch.protectedDirectories
            )
            try settings.write(to: settingsFile, options: .atomic)
        } catch {
            throw .runDirectoryUnwritable("\(error)")
        }
        arguments += ["--settings", settingsFile.path(percentEncoded: false)]

        let permissions = Self.permissions(for: dispatch.pass)
        arguments += ["--permission-mode", permissions.mode, "--allowedTools", permissions.allowed]
        if let disallowed = permissions.disallowed {
            arguments += ["--disallowedTools", disallowed]
        }
        for directory in dispatch.additionalReadableDirectories {
            arguments += ["--add-dir", directory]
        }
        for directory in dispatch.additionalWritableDirectories {
            arguments += ["--add-dir", directory]
        }

        return AgentCLILaunch(
            executable: dispatch.executable,
            arguments: arguments,
            environment: dispatch.environment,
            worktreePath: dispatch.worktreePath,
            resultFile: resultFile,
            pass: dispatch.pass,
            timeout: dispatch.timeout,
            outputLog: dispatch.runDirectory.appendingPathComponent("stderr.log"),
            standardOutput: dispatch.runDirectory.appendingPathComponent(Self.stdoutFileName)
        )
    }

    public func collect(end: RunEnd, dispatch: CLIDispatch) -> CLISession? {
        let sessionIDFile = dispatch.runDirectory.appendingPathComponent(Self.sessionIDFileName)
        let launchedSessionID = (try? String(contentsOf: sessionIDFile, encoding: .utf8))
            .map { CLISession(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let fallback = dispatch.resume ?? launchedSessionID

        let stdoutFile = dispatch.runDirectory.appendingPathComponent(Self.stdoutFileName)
        guard let data = try? Data(contentsOf: stdoutFile), let object = Self.lastParseableObject(in: data) else {
            return fallback
        }

        let session = (object["session_id"] as? String).map(CLISession.init(rawValue:)) ?? fallback

        let isError = object["is_error"] as? Bool ?? false
        if !isError, let structuredOutput = object["structured_output"] as? [String: Any] {
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
        guard let data = try? Data(contentsOf: stdout), let object = Self.lastParseableObject(in: data),
              object["type"] as? String == "result", object["is_error"] as? Bool == true,
              object["api_error"] as? String == "usage_limit_reached" else { return nil }
        return .usageLimited(resetHint: object["result"] as? String)
    }

    private struct Permissions {
        let mode: String
        let allowed: String
        let disallowed: String?
    }

    /// Per pass (spec `routing/add-an-agent-cli`): the worker edits and commits unattended under
    /// `acceptEdits`; the architect and reviewer never touch files, so they run under `dontAsk` with
    /// `Edit`/`Write`/`NotebookEdit` explicitly denied.
    ///
    /// Containment (issue #546) is the `--settings` file ``settingsJSON(for:protectedDirectories:)``
    /// writes: the read-only passes run in a sandbox that denies Yellowhammer's configuration directory
    /// and the Keychains and refuses the vendor APIs; the worker gets permission deny rules only.
    private static func permissions(for pass: RunPass) -> Permissions {
        switch pass {
        case .worker:
            Permissions(mode: "acceptEdits", allowed: "Bash Edit Write Read Glob Grep", disallowed: nil)
        case .architect, .reviewer, .selection, .breakdown, .verifier:
            Permissions(
                mode: "dontAsk",
                allowed: "Bash Read Glob Grep",
                disallowed: "Edit Write NotebookEdit"
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
    /// The worker is **not** sandboxed, and its deny rules are best-effort. SwiftPM runs its own
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

    /// `--output-format json` prints one JSON object, but this tolerates surrounding whitespace and,
    /// if the stream somehow holds multiple JSON documents, keeps the last one that parses.
    private static func lastParseableObject(in data: Data) -> [String: Any]? {
        guard let decoded = String(bytes: data, encoding: .utf8) else { return nil }
        let text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let whole = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
            return whole
        }
        var last: [String: Any]?
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] {
                last = object
            }
        }
        return last
    }
}
