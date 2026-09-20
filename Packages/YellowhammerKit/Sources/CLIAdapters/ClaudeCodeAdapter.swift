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
    public let adapterVersion = "1"
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

    private struct Permissions {
        let mode: String
        let allowed: String
        let disallowed: String?
    }

    /// Per pass (spec `routing/add-an-agent-cli`): the worker edits and commits unattended under
    /// `acceptEdits`; the architect and reviewer never touch files, so they run under `dontAsk` with
    /// `Edit`/`Write`/`NotebookEdit` explicitly denied.
    private static func permissions(for pass: RunPass) -> Permissions {
        switch pass {
        case .worker:
            Permissions(mode: "acceptEdits", allowed: "Bash Edit Write Read Glob Grep", disallowed: nil)
        case .architect, .reviewer, .selection, .breakdown:
            Permissions(
                mode: "dontAsk",
                allowed: "Bash Read Glob Grep",
                disallowed: "Edit Write NotebookEdit"
            )
        }
    }

    // MARK: - Stdout parsing

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
