import Domain
import Foundation

/// The `agy` (Google Antigravity) CLI Adapter (spec `routing/add-an-agent-cli`; measured live
/// against agy 1.2.16).
///
/// Forces structured output with `--json-schema` in the Gemini dialect
/// (``CLIOutputSchema/gemini(for:)``: agy forwards the schema as a Gemini function declaration, which
/// refuses the strict dialect's integer `version` enum with `INVALID_ARGUMENT`), reads it back from the top-level
/// `structured_output` field of `--output-format json`'s stdout, and resumes a conversation with
/// `--conversation <conversation_id>`. agy has no flag to pre-choose a fresh conversation id, so
/// when stdout cannot be parsed ``collect(end:dispatch:)`` falls back to `dispatch.resume` (like
/// Codex): a first dispatch whose stdout is lost has no session to resume.
///
/// **Weaker read-only guarantee.** Every pass runs with `--dangerously-skip-permissions` and without
/// `--sandbox`. Headless `--mode plan` stalls waiting for plan approval, the default mode auto-denies
/// any shell command and aborts the run (the reviewer and architect must run `git log`/`git diff`),
/// and `--sandbox` makes `.git` unwritable, blocks `~/.gitconfig`, and cannot read a linked
/// Worktree's git common dir outside the workspace. agy headless offers no per-run tool deny list, so
/// the read-only passes (architect, reviewer, selection, breakdown, verifier) are kept read-only by
/// the rendered instruction alone. Codex enforces this with an OS sandbox and Claude by denying its
/// Edit/Write tools; a future adapter version can revisit it once agy offers an equivalent.
///
/// A tool permission denied in headless mode still exits 0 with `status: "SUCCESS"` but carries no
/// `structured_output`, so ``collect(end:dispatch:)`` materializes `result.json` only from a present
/// structured-output object.
public struct AntigravityAdapter: CLIAdapter {
    public let cli = "agy"
    public let adapterVersion = "1"
    /// `agy --help`'s `--effort` choices.
    public let supportedEfforts = ["low", "medium", "high", "xhigh", "max"]

    public init() {}

    public func launch(for dispatch: CLIDispatch) throws(CLIAdapterError) -> AgentCLILaunch {
        try validateRoute(dispatch)
        let resultFile = try prepareRunDirectory(dispatch)

        var arguments = [
            "-p", dispatch.instruction,
            "--output-format", "json",
            "--json-schema", CLIOutputSchema.gemini(for: dispatch.pass),
            "--model", dispatch.route.model,
            "--effort", dispatch.route.effort
        ]
        if let resume = dispatch.resume {
            arguments += ["--conversation", resume.rawValue]
        }
        arguments.append("--dangerously-skip-permissions")
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
        let stdoutFile = dispatch.runDirectory.appendingPathComponent(Self.stdoutFileName)
        guard let data = try? Data(contentsOf: stdoutFile), let object = Self.lastParseableObject(in: data) else {
            return dispatch.resume
        }

        let session = (object["conversation_id"] as? String).map(CLISession.init(rawValue:)) ?? dispatch.resume

        let status = object["status"] as? String
        if status == nil || status == "SUCCESS", let structuredOutput = object["structured_output"] as? [String: Any] {
            let resultFile = dispatch.runDirectory.appendingPathComponent("result.json")
            // The forced schema declares optional fields nullable; the Domain schema wants them absent.
            let members = structuredOutput.filter { !($0.value is NSNull) }
            if let data = try? JSONSerialization.data(withJSONObject: members, options: [.sortedKeys]) {
                try? data.write(to: resultFile)
            }
        }
        return session
    }

    // MARK: - Stdout parsing

    private static let stdoutFileName = "stdout.json"

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
