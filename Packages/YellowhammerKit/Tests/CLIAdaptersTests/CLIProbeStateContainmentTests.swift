@testable import CLIAdapters
import Domain
import Foundation
import Testing

/// The state-containment finding (issue #557): the reach line's parser and classification on plain
/// strings, and the probe run end to end against a stub CLI and a stub Keychain — never the real
/// Keychain, never the network.
@Suite("CLIProbe state containment")
struct CLIProbeStateContainmentTests {
    // MARK: - Parser

    @Test("The fully blocked line parses with no leaks")
    func blockedLineParses() throws {
        let line = try #require(CLIProbe.parseReachLine("keychain=blocked config=blocked linear=blocked"))
        #expect(line.leaks.isEmpty)
    }

    @Test("Each leak is named, in the line's order")
    func leaksAreNamed() throws {
        let line = try #require(CLIProbe.parseReachLine("keychain=readable config=readable linear=reachable"))
        #expect(line.leaks == ["keychain readable", "config readable", "linear reachable"])
    }

    @Test("Surrounding whitespace and a trailing newline are tolerated, and key order does not matter")
    func whitespaceAndOrderTolerated() throws {
        let line = try #require(CLIProbe.parseReachLine("  linear=blocked keychain=blocked  config=readable\n"))
        #expect(line.leaks == ["config readable"])
    }

    @Test(
        "Anything but exactly the three known pairs is not a reach line",
        arguments: [
            "",
            "keychain=blocked config=blocked",
            "keychain=blocked config=blocked linear=blocked extra=1",
            "keychain=blocked config=blocked linear=readable",
            "keychain=maybe config=blocked linear=blocked",
            "keychain=blocked keychain=blocked linear=blocked",
            "The command printed: keychain=blocked config=blocked linear=blocked",
            "`keychain=blocked config=blocked linear=blocked`",
            "yh-probe-account"
        ]
    )
    func garbageIsRejected(text: String) {
        #expect(CLIProbe.parseReachLine(text) == nil)
    }

    // MARK: - Classification

    private static func runReport(end: RunEnd, outcome: RunOutcome) -> CLIRunReport {
        CLIRunReport(
            pid: 1, end: end, outcome: outcome, session: nil, leftovers: [],
            snapshot: RunningSnapshot(
                dispatchedAt: ProcessStartTime(seconds: 0, microseconds: 0), processes: [], processGroups: [],
                sessions: []
            )
        )
    }

    private static func architectReport(reason: String) -> Result<CLIRunReport, Error> {
        let result = ArchitectResult(outcome: .failed(reason: reason))
        return .success(runReport(end: .exited(status: 0), outcome: .completed(.architect(result))))
    }

    @Test("All three blocked passes")
    func allBlockedPasses() {
        let (finding, detail) = CLIProbe.stateContainmentFinding(
            for: Self.architectReport(reason: "keychain=blocked config=blocked linear=blocked")
        )
        #expect(finding == .passed)
        #expect(detail == nil)
    }

    @Test("One readable read fails, naming it")
    func oneLeakFails() {
        let (finding, detail) = CLIProbe.stateContainmentFinding(
            for: Self.architectReport(reason: "keychain=blocked config=readable linear=blocked")
        )
        #expect(finding == .failed)
        #expect(detail == "state containment: config readable")
    }

    @Test("Several leaks are joined with commas, so the finding stays one clause of the reason")
    func severalLeaksFail() {
        let (finding, detail) = CLIProbe.stateContainmentFinding(
            for: Self.architectReport(reason: "keychain=readable config=readable linear=blocked")
        )
        #expect(finding == .failed)
        #expect(detail == "state containment: keychain readable, config readable")
    }

    @Test("A reason that is not the reach line fails as not reported")
    func garbageFailsAsNotReported() {
        let (finding, detail) = CLIProbe.stateContainmentFinding(
            for: Self.architectReport(reason: "I cannot run that command.")
        )
        #expect(finding == .failed)
        #expect(detail == "state containment: the pass did not report the reach script's line")
    }

    @Test("A pass that ended without a result fails as not reported")
    func noResultFailsAsNotReported() {
        let report = Self.runReport(end: .exited(status: 1), outcome: .failed(exitStatus: 1))
        let (finding, detail) = CLIProbe.stateContainmentFinding(for: .success(report))
        #expect(finding == .failed)
        #expect(detail == "state containment: the pass did not report the reach script's line")
    }

    @Test("A dispatch that never ran is not run")
    func failedDispatchIsNotRun() {
        let (finding, detail) = CLIProbe.stateContainmentFinding(
            for: .failure(CLIAdapterError.routeForOtherCLI(expected: "stub", got: "other"))
        )
        #expect(finding == .notRun)
        #expect(detail?.hasPrefix("state containment: not run:") == true)
    }

    // MARK: - Instruction and script

    @Test("The instruction names the reach script and no path")
    func instructionNamesNoPath() {
        let instruction = CLIProbe.stateContainmentInstruction
        #expect(instruction.contains("`sh yh-probe-reach.sh`"))
        #expect(instruction.contains("outcome `failed`"))
        #expect(!instruction.contains("/"))
    }

    @Test("The reach script reads only the probe's own Keychain item and the shell-quoted directory")
    func reachScriptReadsTheProbeItem() {
        let script = CLIProbe.reachScriptContents(
            CLIProbe.ReachTargets(keychainAccount: "yh-probe-account", configurationDirectory: "/Users/o'b/a b")
        )
        #expect(script.contains("config_dir='/Users/o'\\''b/a b'"))
        #expect(script.contains("service=\"dev.yellowhammer.probe\""))
        #expect(script.contains("account=\"yh-probe-account\""))
        #expect(script.contains("printf 'keychain=%s config=%s linear=%s\\n'"))
        #expect(!script.contains("-s dev.yellowhammer "))
    }

    // MARK: - End to end against a stub CLI

    private static let protectedDirectories = CLIProbeTests.protectedDirectories
    private static let route = Route(cli: "stub", model: "some-model", effort: "low")!

    private func makeWorkDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yh-557-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func runProbe(
        keychain: StubProbeKeychain, workDirectory: URL, reachLine: String? = nil
    ) async throws -> ProbeReport {
        // Beside the work directory, not in it, so a work directory that cannot be used still has a CLI.
        let executable = workDirectory.deletingLastPathComponent()
            .appendingPathComponent("cli-\(UUID().uuidString).sh")
        try StubProbeCLI.write(StubProbeCLI.healthy, to: executable)
        defer { try? FileManager.default.removeItem(at: executable) }
        var environment = ProcessInfo.processInfo.environment
        environment["STUB_REACH_LINE"] = reachLine
        let probe = CLIProbe(
            dispatchTimeout: .seconds(10), holdObservationTimeout: .seconds(5),
            pollInterval: .milliseconds(50), gracePeriod: .milliseconds(300), keychain: keychain.keychain
        )
        return await probe.run(
            adapter: StubProbeAdapter(), route: Self.route, executable: executable.path,
            environment: environment, workDirectory: workDirectory,
            protectedDirectories: Self.protectedDirectories
        )
    }

    @Test("Every probe dispatch carries the protected directories, as a real dispatch does")
    func everyDispatchCarriesProtectedDirectories() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let report = try await runProbe(keychain: StubProbeKeychain(), workDirectory: workDirectory)

        #expect(report.unattendedDispatch == .passed)
        for run in ["unattended", "resume", "sigterm", "sigkill", "state-containment"] {
            let file = workDirectory.appending(components: "runs", run, StubProbeAdapter.protectedDirectoriesFileName)
            let recorded = try String(contentsOf: file, encoding: .utf8)
            #expect(recorded.split(separator: "\n").map(String.init) == Self.protectedDirectories, "\(run)")
        }
    }

    @Test("The Keychain item is created once, then deleted after the reach dispatch")
    func keychainItemIsCreatedThenDeleted() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let keychain = StubProbeKeychain()

        let report = try await runProbe(keychain: keychain, workDirectory: workDirectory)

        #expect(report.stateContainment == .passed)
        guard case .create(let account) = try #require(keychain.calls.first) else {
            Issue.record("expected a create first, got \(keychain.calls)")
            return
        }
        #expect(keychain.calls == [.create(account), .delete(account)])
        #expect(account.hasPrefix("yh-probe-"))
        // The script the pass ran looks for exactly that item.
        let script = try String(
            contentsOf: workDirectory.appending(components: "worktree", "yh-probe-reach.sh"), encoding: .utf8
        )
        #expect(script.contains("account=\"\(account)\""))
        #expect(script.contains("config_dir='\(Self.protectedDirectories[0])'"))
    }

    @Test("A leak the pass reports fails the finding, and the item is still deleted")
    func reportedLeakFails() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let keychain = StubProbeKeychain()

        let report = try await runProbe(
            keychain: keychain, workDirectory: workDirectory,
            reachLine: "keychain=blocked config=readable linear=blocked"
        )

        #expect(report.stateContainment == .failed)
        #expect(report.reason?.contains("state containment: config readable") == true)
        // Non-gating findings never disturb the gating ones.
        #expect(report.unattendedDispatch == .passed)
        #expect(report.processContainment == .passed)
        #expect(keychain.calls.count == 2)
        #expect(keychain.calls.last.map { if case .delete = $0 { true } else { false } } == true)
    }

    @Test("When the item cannot be created, the finding is not run, nothing is dispatched, and it is deleted")
    func uncreatableItemIsNotRun() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let keychain = StubProbeKeychain(createSucceeds: false)

        let report = try await runProbe(keychain: keychain, workDirectory: workDirectory)

        #expect(report.stateContainment == .notRun)
        #expect(report.reason?.contains("could not create the probe's Keychain item") == true)
        let runDirectory = workDirectory.appending(components: "runs", "state-containment")
        #expect(!FileManager.default.fileExists(atPath: runDirectory.path))
        guard case .create(let account) = try #require(keychain.calls.first) else {
            Issue.record("expected a create first, got \(keychain.calls)")
            return
        }
        #expect(keychain.calls == [.create(account), .delete(account)])
    }

    @Test("A setup failure never creates a Keychain item and reports state containment not run")
    func setupFailureCreatesNothing() async throws {
        let parent = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        // A work directory that is a file: the Worktree under it cannot be created.
        let workDirectory = parent.appendingPathComponent("not-a-directory")
        try Data().write(to: workDirectory)
        let keychain = StubProbeKeychain()

        let report = try await runProbe(keychain: keychain, workDirectory: workDirectory)

        #expect(report.stateContainment == .notRun)
        #expect(report.reason?.hasPrefix("setup failed") == true)
        #expect(keychain.calls.isEmpty)
    }

    @Test("With no protected directories there is nothing to check, so no item is created")
    func noProtectedDirectoriesIsNotRun() async throws {
        let workDirectory = try makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        let executable = workDirectory.appendingPathComponent("cli.sh")
        try StubProbeCLI.write(StubProbeCLI.healthy, to: executable)
        let keychain = StubProbeKeychain()

        let report = await CLIProbe(
            dispatchTimeout: .seconds(10), holdObservationTimeout: .seconds(5),
            pollInterval: .milliseconds(50), gracePeriod: .milliseconds(300), keychain: keychain.keychain
        ).run(
            adapter: StubProbeAdapter(), route: Self.route, executable: executable.path,
            workDirectory: workDirectory, protectedDirectories: []
        )

        #expect(report.stateContainment == .notRun)
        #expect(keychain.calls.isEmpty)
    }
}
