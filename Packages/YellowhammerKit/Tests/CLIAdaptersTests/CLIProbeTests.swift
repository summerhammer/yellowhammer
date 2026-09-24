import Darwin
@testable import CLIAdapters
import Domain
import Foundation
import Testing

/// Exercises ``CLIProbe`` end to end against stub `/bin/sh` executables standing in for a real
/// agent CLI (never a live `claude` or `codex`). Every scenario keeps timeouts short, so the whole
/// suite stays well under the wall-time budget.
@Suite("CLIProbe against stub CLIs", .serialized)
struct CLIProbeTests {
    private static let route = Route(cli: "stub", model: "some-model", effort: "low")!

    private func makeProbe() -> CLIProbe {
        CLIProbe(
            dispatchTimeout: .seconds(10),
            holdObservationTimeout: .seconds(5),
            pollInterval: .milliseconds(50),
            gracePeriod: .milliseconds(300)
        )
    }

    private func makeWorkDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yh-p74-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExecutable(_ script: String, in workDirectory: URL) throws -> String {
        let url = workDirectory.appendingPathComponent("cli-\(UUID().uuidString).sh")
        try StubProbeCLI.write(script, to: url)
        return url.path
    }

    /// Polls until `pid` is dead, up to 500 ms — a just-killed pid can be a zombie briefly, during
    /// which `kill(pid, 0)` still succeeds.
    private static func awaitDead(_ pid: pid_t) async {
        for _ in 0..<25 {
            if kill(pid, 0) == -1 && errno == ESRCH { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("A fully healthy stub CLI passes every probe target")
    func healthyStubPassesEveryTarget() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let executable = try makeExecutable(StubProbeCLI.healthy, in: workDirectory)

        let report = await makeProbe().run(
            adapter: StubProbeAdapter(), route: Self.route, executable: executable,
            environment: ProcessInfo.processInfo.environment, workDirectory: workDirectory
        )

        #expect(report.unattendedDispatch == .passed)
        #expect(report.resultFileOnCleanExit == .passed)
        #expect(report.sessionResumption == .passed)
        #expect(report.processContainment == .passed)
        #expect(report.reason == nil)
        #expect(report.cliVersion == "stub-cli 9.9.9")
        #expect(report.adapterVersion == "test")
    }

    @Test("A stub CLI that refuses every pass as not logged in fails unattended dispatch")
    func brokenStubFailsUnattended() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let executable = try makeExecutable(StubProbeCLI.notLoggedIn, in: workDirectory)

        let report = await makeProbe().run(
            adapter: StubProbeAdapter(), route: Self.route, executable: executable,
            environment: ProcessInfo.processInfo.environment, workDirectory: workDirectory
        )

        #expect(report.unattendedDispatch == .failed)
        #expect(report.resultFileOnCleanExit == .notRun)
        #expect(report.sessionResumption == .notRun)
        #expect(report.processContainment == .failed)
        let reason = try #require(report.reason)
        #expect(reason.contains("exited 1"))
        #expect(reason.contains("Not logged in"))
    }

    @Test("A stub CLI that hangs on a dispatch fails unattended dispatch as an interactive prompt")
    func hangingStubFailsUnattendedAsInteractive() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let executable = try makeExecutable(StubProbeCLI.hangs, in: workDirectory)

        let report = await CLIProbe(
            dispatchTimeout: .seconds(1), holdObservationTimeout: .seconds(2),
            pollInterval: .milliseconds(50), gracePeriod: .milliseconds(300)
        ).run(
            adapter: StubProbeAdapter(), route: Self.route, executable: executable,
            environment: ProcessInfo.processInfo.environment, workDirectory: workDirectory
        )

        #expect(report.unattendedDispatch == .failed)
        let reason = try #require(report.reason)
        #expect(reason.contains("interactive"))
    }

    @Test("A stub CLI that escapes its process group is still contained by the abort path's descendant sweep")
    func escapingStubIsContainedByDescendantSweep() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let executable = try makeExecutable(StubProbeCLI.escapes, in: workDirectory)

        let report = await makeProbe().run(
            adapter: StubProbeAdapter(), route: Self.route, executable: executable,
            environment: ProcessInfo.processInfo.environment, workDirectory: workDirectory
        )

        // The escaped tool subprocess is a direct child of the CLI leader (`setsid` never changes
        // `ppid`), so the abort path's descendant sweep (`AgentCLIProcess+Termination.swift`)
        // finds and signals it directly, by pid identity, even though it moved to a new process
        // group of its own. Containment now passes.
        #expect(report.processContainment == .passed)

        // No orphan survives the probe: give the detached descendants a moment to actually die
        // after the probe's own SIGKILL, then confirm none of the recorded hold pids remain.
        for variant in ["sigterm", "sigkill"] {
            let holdsFile = workDirectory
                .appendingPathComponent("worktree/.yh-probe/holds-\(variant)")
            guard let text = try? String(contentsOf: holdsFile, encoding: .utf8) else { continue }
            let pids = text.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            for pid in pids {
                #expect(kill(pid, 0) == -1 && errno == ESRCH, "pid \(pid) (\(variant)) should be dead")
            }
        }
    }

    @Test("A stub CLI that daemonizes the hold script fails containment as never having been a descendant")
    func daemonizingStubFailsContainmentAsNotADescendant() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let executable = try makeExecutable(StubProbeCLI.daemonizes, in: workDirectory)

        let report = await makeProbe().run(
            adapter: StubProbeAdapter(), route: Self.route, executable: executable,
            environment: ProcessInfo.processInfo.environment, workDirectory: workDirectory
        )

        #expect(report.processContainment == .failed)
        let reason = try #require(report.reason)
        #expect(reason.contains("were not descendants of the CLI"))

        // The reason names the real CLI leader pid, so it is unmistakable which run this is about.
        for variant in ["sigterm", "sigkill"] {
            let leaderFile = workDirectory.appendingPathComponent("worktree/.yh-probe-leader-\(variant)")
            guard let leaderText = try? String(contentsOf: leaderFile, encoding: .utf8) else { continue }
            let leaderPID = leaderText.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(reason.contains("(pid \(leaderPID))"))
        }

        // No orphan survives the probe: a just-killed pid can be a zombie briefly (`kill(pid, 0)`
        // still succeeds on one), so poll for real death rather than asserting immediately.
        for variant in ["sigterm", "sigkill"] {
            let holdsFile = workDirectory.appendingPathComponent("worktree/.yh-probe/holds-\(variant)")
            guard let text = try? String(contentsOf: holdsFile, encoding: .utf8) else { continue }
            let pids = text.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            for pid in pids {
                await Self.awaitDead(pid)
                #expect(kill(pid, 0) == -1 && errno == ESRCH, "pid \(pid) (\(variant)) should be dead")
            }
        }
    }

    @Test("A stub CLI that exits 0 without writing a result file fails only resultFileOnCleanExit")
    func cleanExitWithoutResultFileFailsOnlyResultFile() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let executable = try makeExecutable(StubProbeCLI.cleanExitNoResult, in: workDirectory)

        let report = await makeProbe().run(
            adapter: StubProbeAdapter(), route: Self.route, executable: executable,
            environment: ProcessInfo.processInfo.environment, workDirectory: workDirectory
        )

        #expect(report.unattendedDispatch == .passed)
        #expect(report.resultFileOnCleanExit == .failed)
    }
}
