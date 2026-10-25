import Domain
import Foundation

/// The `codex` CLI Adapter (spec `routing/add-an-agent-cli`; probe evidence:
/// `attachments/investigations/2026-09-13-feasibility-probes/cli-probe.md`).
///
/// Forces structured output with `--output-schema <file>` and `-o <file>` (codex writes
/// `result.json` itself; ``collect(end:dispatch:)`` only strips its strict-mode `null` members), and
/// resumes a session with
/// `codex exec resume <thread_id>`. `codex exec resume` has neither `--sandbox` nor `-C`/`--add-dir`
/// — the sandbox is re-stated with `-c sandbox_mode=…`; cwd is already the Worktree, set by
/// `posix_spawn`. Workers run with `danger-full-access` under the unsandboxed-worker ruling (#553).
///
/// **Containment (issues #546 and #557), measured live with codex-cli 0.163.0.** The
/// `read-only` Seatbelt sandbox blocks Keychain reads and network access, so a read-only pass
/// cannot pull a credential out of the login Keychain or call a vendor API. It does not stop reads of
/// Yellowhammer's configuration directory. A read-only pass with `CLIDispatch.protectedDirectories`
/// therefore runs under a named permissions profile instead of `--sandbox read-only`:
/// `default_permissions="yellowhammer"`, a profile that `extends = ":read-only"` and marks each
/// protected directory `"deny"` in its `filesystem` table, all given as `-c` overrides. Measured: the
/// configuration directory reads as "Operation not permitted" while the Worktree stays readable, on a
/// fresh `codex exec` and on `codex exec resume`. The `--sandbox` flag overrides `default_permissions`
/// (with both, the directory was readable again), so the flag is dropped, not added alongside; on
/// resume the profile replaces `-c sandbox_mode`. With no protected directories the plain
/// `read-only` sandbox is kept.
///
/// Workers have no enforced filesystem, network or Keychain containment. Additional writable roots
/// are redundant with `danger-full-access` and are omitted. Only the prompt's boundary statement
/// asks a worker to avoid Yellowhammer's state, the Keychain and vendor APIs; the Probe measures
/// read-only passes, not this worker shape.
public struct CodexAdapter: CLIAdapter {
    public let cli = "codex"
    public let adapterVersion = "4"
    /// `codex exec --help`'s `-c model_reasoning_effort` values.
    public let supportedEfforts = ["minimal", "low", "medium", "high", "xhigh"]

    public init() {}

    public func outputSchema(for pass: RunPass) -> String {
        CLIOutputSchema.strict(for: pass)
    }

    public func launch(for dispatch: CLIDispatch) throws(CLIAdapterError) -> AgentCLILaunch {
        try validateRoute(dispatch)
        let resultFile = try prepareRunDirectory(dispatch)
        let schemaFile = dispatch.runDirectory.appendingPathComponent("schema.json")
        do {
            try Data(outputSchema(for: dispatch.pass).utf8).write(to: schemaFile)
        } catch {
            throw .runDirectoryUnwritable("\(error)")
        }

        var arguments = ["exec"]

        if let resume = dispatch.resume {
            arguments += ["resume", "--json"] + Self.sandboxArguments(for: dispatch)
            arguments += [
                "-m", dispatch.route.model,
                "-c", "model_reasoning_effort=\(Self.tomlString(dispatch.route.effort))",
                "--output-schema", schemaFile.path,
                "-o", resultFile.path,
                "--", resume.rawValue, dispatch.instruction
            ]
        } else {
            arguments += ["--json"] + Self.sandboxArguments(for: dispatch)
            arguments += [
                "-m", dispatch.route.model,
                "-c", "model_reasoning_effort=\(Self.tomlString(dispatch.route.effort))",
                "--output-schema", schemaFile.path,
                "-o", resultFile.path
            ]
            if dispatch.pass != .worker {
                for directory in dispatch.additionalWritableDirectories {
                    arguments += ["--add-dir", directory]
                }
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

    public func usageLimit(for dispatch: CLIDispatch) -> RunOutcome? {
        let stdout = dispatch.runDirectory.appendingPathComponent(Self.stdoutFileName)
        guard let text = try? String(contentsOf: stdout, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            let message: String?
            switch object["type"] as? String {
            case "error": message = object["message"] as? String
            case "turn.failed": message = (object["error"] as? [String: Any])?["message"] as? String
            default: message = nil
            }
            guard let message else { continue }
            let normalized = message.replacingOccurrences(of: "’", with: "'").lowercased()
            if normalized.hasPrefix("you've hit your usage limit.") {
                return .usageLimited(resetHint: message)
            }
        }
        return nil
    }

    /// Workers run unsandboxed (#553); every other pass runs read-only.
    private static func sandboxMode(for pass: RunPass) -> String {
        switch pass {
        case .worker: "danger-full-access"
        case .architect, .reviewer, .selection, .breakdown, .verifier: "read-only"
        }
    }

    /// How the pass is sandboxed. A fresh dispatch names the sandbox with `--sandbox`; `codex exec resume`
    /// has no such flag, so a Round re-states it with `-c`. A read-only
    /// pass with protected directories uses the deny profile instead, fresh or resumed.
    private static func sandboxArguments(for dispatch: CLIDispatch) -> [String] {
        let sandbox = sandboxMode(for: dispatch.pass)
        let protectedDirectories = dispatch.protectedDirectories
        if let profile = readOnlyProfileOverrides(sandbox: sandbox, protectedDirectories: protectedDirectories) {
            return profile
        }
        guard dispatch.resume != nil else { return ["--sandbox", sandbox] }
        return ["-c", "sandbox_mode=\(tomlString(sandbox))"]
    }

    /// The name of the permissions profile a contained read-only pass runs under. Distinct enough not
    /// to merge with a `[permissions.*]` profile in the Operator's own `~/.codex/config.toml`.
    static let permissionsProfileName = "yellowhammer"

    /// The `-c` overrides that select a read-only profile denying every protected directory, or `nil`
    /// when the pass is not read-only or there is nothing to deny (then the plain sandbox is used).
    private static func readOnlyProfileOverrides(sandbox: String, protectedDirectories: [String]) -> [String]? {
        guard sandbox == "read-only", !protectedDirectories.isEmpty else { return nil }
        let name = permissionsProfileName
        let denials = protectedDirectories.map { "\(tomlString($0))=\"deny\"" }.joined(separator: ",")
        return [
            "-c", "default_permissions=\(tomlString(name))",
            "-c", "permissions.\(name).extends=\(tomlString(":read-only"))",
            "-c", "permissions.\(name).filesystem={\(denials)}"
        ]
    }

    // MARK: - TOML literals for `-c`

    private static func tomlString(_ value: String) -> String {
        "\"\(escapeTOML(value))\""
    }

    private static func escapeTOML(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static let stdoutFileName = "stdout.jsonl"
}
