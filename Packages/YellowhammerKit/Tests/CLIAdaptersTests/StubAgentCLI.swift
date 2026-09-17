import CLIAdapters
import Darwin
import Domain
import Foundation

/// Builds a per-test `#!/bin/sh` stub that stands in for an agent CLI, so
/// `AgentCLIProcessTests` can exercise the real `posix_spawn` lifecycle without a live CLI.
///
/// Every stub script receives the result file path as `$1` and a scratch directory as `$2`, so
/// scripts can report what they saw (cwd, pgid, pid, child pids) back to the test.
enum StubAgentCLI {
    /// A schema-valid `yellowhammer.result.worker` result file, `outcome: completed`.
    static let validWorkerJSON =
        """
        {"schema":"yellowhammer.result.worker","version":1,"outcome":"completed",\
        "commit":"0123456789abcdef0123456789abcdef01234567","summary":"stub"}
        """

    // MARK: - Named scenario scripts

    /// Writes a valid result file, then exits 0.
    static let cleanExit = shell(
        """
        printf '%s' '\(validWorkerJSON)' > "$1"
        exit 0
        """
    )

    /// Reports its cwd, process group and pid to the scratch dir, then completes cleanly.
    static let reportsWorktreeAndProcessGroup = shell(
        """
        pwd > "$2/cwd"
        ps -o pgid= -p $$ | tr -d ' ' > "$2/pgid"
        echo $$ > "$2/pid"
        printf '%s' '\(validWorkerJSON)' > "$1"
        """
    )

    /// Reports whether stdin has anything readable, then completes cleanly.
    static let reportsStdinState = shell(
        """
        if read -r line; then echo open > "$2/stdin"; else echo closed > "$2/stdin"; fi
        printf '%s' '\(validWorkerJSON)' > "$1"
        """
    )

    /// Exit 0, but the result file is left empty.
    static let exitZeroEmptyFile = shell(
        """
        : > "$1"
        exit 0
        """
    )

    /// Exit 0, and the result file is never written at all.
    static let exitZeroNoFile = shell(
        """
        exit 0
        """
    )

    /// Exit 0, but the result file is truncated JSON.
    static let exitZeroMalformedFile = shell(
        """
        printf '{"schema":' > "$1"
        exit 0
        """
    )

    /// Writes a valid result file, then exits non-zero — attributable to the CLI, file unread.
    static let nonZeroExitWithValidFile = shell(
        """
        printf '%s' '\(validWorkerJSON)' > "$1"
        exit 3
        """
    )

    /// Kills itself with a signal Yellowhammer never sent.
    static let killedByForeignSignal = shell(
        """
        kill -KILL $$
        """
    )

    /// Ignores nothing: spawns a child that ignores SIGTERM, then the leader itself honors SIGTERM
    /// by exiting. The orphaned child is left for the SIGKILL escalation to contain.
    static let leaderHonorsTermButLeavesOrphan = shell(
        """
        ( trap '' TERM; echo $$ > "$2/child"; sleep 60 ) &
        echo $! > "$2/child"
        trap 'echo term > "$2/term"; exit 0' TERM
        sleep 60
        """
    )

    /// The whole group (just the leader) exits cleanly on SIGTERM.
    static let wholeGroupExitsOnTerm = shell(
        """
        trap 'exit 0' TERM
        sleep 60
        """
    )

    /// Neither the leader nor its child ever honor SIGTERM.
    static let groupIgnoresTermEverywhere = shell(
        """
        trap '' TERM
        ( trap '' TERM; sleep 60 ) &
        echo $! > "$2/child"
        sleep 60
        """
    )

    /// Writes to both stdout and stderr, then completes cleanly.
    static let writesStdoutAndStderr = shell(
        """
        echo out
        echo err >&2
        printf '%s' '\(validWorkerJSON)' > "$1"
        """
    )

    private static func shell(_ body: String) -> String {
        "#!/bin/sh\n\(body)\n"
    }

    // MARK: - Fixture

    /// One test's isolated temp dir, holding the script, its Worktree, a scratch dir, and the
    /// path the script is told to write the result file to.
    struct Fixture {
        let tempDir: URL
        let worktree: URL
        let scratch: URL
        let resultFile: URL
        let scriptPath: URL

        func launch(timeout: Duration = .seconds(5), outputLog: URL? = nil, pass: RunPass = .worker) -> AgentCLILaunch {
            AgentCLILaunch(
                executable: scriptPath.path,
                arguments: [resultFile.path, scratch.path],
                environment: [:],
                worktreePath: worktree.path,
                resultFile: resultFile,
                pass: pass,
                timeout: timeout,
                outputLog: outputLog
            )
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    static func makeFixture(script: String) throws -> Fixture {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("yh-p72-\(UUID().uuidString)")
        let worktree = tempDir.appendingPathComponent("worktree")
        let scratch = tempDir.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let resultFile = tempDir.appendingPathComponent("result.json")
        let scriptPath = tempDir.appendingPathComponent("cli.sh")

        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        return Fixture(
            tempDir: tempDir, worktree: worktree, scratch: scratch, resultFile: resultFile, scriptPath: scriptPath
        )
    }

    // MARK: - Assertions shared across tests

    /// Whether `pid` is dead: `kill(pid, 0)` fails with `ESRCH`.
    static func isDead(_ pid: pid_t) -> Bool {
        kill(pid, 0) == -1 && errno == ESRCH
    }

    /// Reads a pid a stub script wrote (as plain text, possibly with trailing whitespace) to a
    /// scratch file.
    static func readPID(at url: URL) -> pid_t? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return pid_t(trimmed)
    }
}
