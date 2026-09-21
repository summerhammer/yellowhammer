import Domain
import Foundation

/// The `codex` CLI Adapter (spec `routing/add-an-agent-cli`; probe evidence:
/// `attachments/investigations/2026-09-13-feasibility-probes/cli-probe.md`).
///
/// Forces structured output with `--output-schema <file>` and `-o <file>` (codex writes
/// `result.json` itself; ``collect(end:dispatch:)`` only strips its strict-mode `null` members), and
/// resumes a session with
/// `codex exec resume <thread_id>`. `codex exec resume` has neither `--sandbox` nor `-C`/`--add-dir`
/// — the sandbox and any extra writable roots are re-stated with `-c sandbox_mode=…` and
/// `-c sandbox_workspace_write.writable_roots=[…]`; cwd is already the Worktree, set by `posix_spawn`.
public struct CodexAdapter: CLIAdapter {
    public let cli = "codex"
    public let adapterVersion = "1"
    /// `codex exec --help`'s `-c model_reasoning_effort` values.
    public let supportedEfforts = ["minimal", "low", "medium", "high", "xhigh"]

    public init() {}

    public func launch(for dispatch: CLIDispatch) throws(CLIAdapterError) -> AgentCLILaunch {
        try validateRoute(dispatch)
        let resultFile = try prepareRunDirectory(dispatch)
        let schemaFile = dispatch.runDirectory.appendingPathComponent("schema.json")
        do {
            try Data(CLIOutputSchema.strict(for: dispatch.pass).utf8).write(to: schemaFile)
        } catch {
            throw .runDirectoryUnwritable("\(error)")
        }

        let sandbox = Self.sandboxMode(for: dispatch.pass)
        var arguments = ["exec"]

        if let resume = dispatch.resume {
            arguments += ["resume", "--json", "-c", "sandbox_mode=\(Self.tomlString(sandbox))"]
            if sandbox == "workspace-write", !dispatch.additionalWritableDirectories.isEmpty {
                let writableRoots = Self.tomlStringArray(dispatch.additionalWritableDirectories)
                arguments += ["-c", "sandbox_workspace_write.writable_roots=\(writableRoots)"]
            }
            arguments += [
                "-m", dispatch.route.model,
                "-c", "model_reasoning_effort=\(Self.tomlString(dispatch.route.effort))",
                "--output-schema", schemaFile.path,
                "-o", resultFile.path,
                "--", resume.rawValue, dispatch.instruction
            ]
        } else {
            arguments += ["--json", "--sandbox", sandbox]
            arguments += [
                "-m", dispatch.route.model,
                "-c", "model_reasoning_effort=\(Self.tomlString(dispatch.route.effort))",
                "--output-schema", schemaFile.path,
                "-o", resultFile.path
            ]
            for directory in dispatch.additionalWritableDirectories {
                arguments += ["--add-dir", directory]
            }
            arguments += ["--", dispatch.instruction]
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

    /// codex writes `result.json` itself; this strips the `null` members strict mode forces onto
    /// optional fields, then extracts the session to resume from the `thread.started` JSONL event
    /// `--json` prints.
    public func collect(end: RunEnd, dispatch: CLIDispatch) -> CLISession? {
        let resultFile = dispatch.runDirectory.appendingPathComponent("result.json")
        if let data = try? Data(contentsOf: resultFile),
            let normalized = CLIOutputSchema.removingNullMembers(from: data) {
            try? normalized.write(to: resultFile)
        }

        let stdoutFile = dispatch.runDirectory.appendingPathComponent(Self.stdoutFileName)
        guard let data = try? Data(contentsOf: stdoutFile), let text = String(bytes: data, encoding: .utf8) else {
            return dispatch.resume
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                continue
            }
            if object["type"] as? String == "thread.started", let threadID = object["thread_id"] as? String {
                return CLISession(rawValue: threadID)
            }
        }
        return dispatch.resume
    }

    // MARK: - Sandbox

    /// Per pass (spec `routing/add-an-agent-cli`): the worker edits and commits, so it needs
    /// `workspace-write`; the architect and reviewer never touch files, so they run `read-only`.
    private static func sandboxMode(for pass: RunPass) -> String {
        switch pass {
        case .worker: "workspace-write"
        case .architect, .reviewer, .selection, .breakdown, .verifier: "read-only"
        }
    }

    // MARK: - TOML literals for `-c`

    private static func tomlString(_ value: String) -> String {
        "\"\(escapeTOML(value))\""
    }

    private static func tomlStringArray(_ values: [String]) -> String {
        "[\(values.map(tomlString).joined(separator: ","))]"
    }

    private static func escapeTOML(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static let stdoutFileName = "stdout.jsonl"
}
