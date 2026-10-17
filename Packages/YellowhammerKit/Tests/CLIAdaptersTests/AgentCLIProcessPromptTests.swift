import CLIAdapters
import Darwin
import Domain
import Foundation
import Testing

// #555: a macOS permission prompt attributed to the run's own process tree ends the run at once, as an
// engine stop; a prompt for any other process never does.

/// Stands in for the unified log: reports a Keychain prompt for whatever pid `clientPID` reads, once it
/// reads one. Records whether the run stopped it.
private actor StubPromptWatch: PromptWatching {
    private let clientPID: @Sendable () -> pid_t?
    private let repeats: Bool
    private var reported = false
    private(set) var stopped = false

    init(repeats: Bool, clientPID: @escaping @Sendable () -> pid_t?) {
        self.repeats = repeats
        self.clientPID = clientPID
    }

    func drain() -> [PromptEvent] {
        guard repeats || !reported, let pid = clientPID() else { return [] }
        reported = true
        let detail = "Keychain prompt for /usr/bin/security (pid \(pid))"
        return [PromptEvent(kind: .keychain, clientPID: pid, detail: detail)]
    }

    func stop() {
        stopped = true
    }
}

private struct StubPromptSource: PromptSource {
    let watch: StubPromptWatch

    func start() async -> (any PromptWatching)? {
        watch
    }
}

private func pid(inFile url: URL) -> pid_t? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

private func process(with watch: StubPromptWatch) -> AgentCLIProcess {
    AgentCLIProcess(gracePeriod: .seconds(3), promptSource: StubPromptSource(watch: watch))
}

@Suite("Agent CLI process: permission prompts", .timeLimit(.minutes(1)))
struct AgentCLIProcessPromptTests {
    /// A tool child that would block forever, as one waiting on a prompt does.
    static let blockedToolChild = """
        #!/bin/sh
        sleep 60 &
        echo $! > "$2/child"
        wait
        """

    @Test("A prompt for a descendant ends the run at once, as an engine stop that excludes no Route")
    func promptForDescendantEndsRun() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: Self.blockedToolChild)
        defer { fixture.cleanUp() }
        let childFile = fixture.scratch.appendingPathComponent("child")
        let watch = StubPromptWatch(repeats: false) { pid(inFile: childFile) }

        let clock = ContinuousClock()
        let start = clock.now
        let report = try await process(with: watch).run(fixture.launch(timeout: .seconds(40)))
        let elapsed = clock.now - start

        let child = try #require(pid(inFile: childFile))
        let detail = "Keychain prompt for /usr/bin/security (pid \(child))"
        #expect(report.end == .promptBlocked(detail: detail, forcedKill: false))
        #expect(elapsed < .seconds(15))
        #expect(report.outcome == .crashedUnknown(.permissionPrompt(detail)))
        let ending = try #require(AttemptEnding(failedRun: report.outcome))
        #expect(ending.excludesRoute == false)
        #expect(ending.classification.hasPrefix("stopped by the engine: a macOS permission prompt blocked the pass: "))
        #expect(await watch.stopped)
    }

    @Test("A prompt for the CLI leader itself ends the run")
    func promptForLeaderEndsRun() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: """
            #!/bin/sh
            echo $$ > "$2/pid"
            sleep 60
            """)
        defer { fixture.cleanUp() }
        let pidFile = fixture.scratch.appendingPathComponent("pid")
        let watch = StubPromptWatch(repeats: false) { pid(inFile: pidFile) }

        let report = try await process(with: watch).run(fixture.launch(timeout: .seconds(40)))

        guard case .promptBlocked = report.end else {
            Issue.record("expected .promptBlocked, got \(report.end)")
            return
        }
        #expect(report.pid == pid(inFile: pidFile))
    }

    @Test("A prompt for an unrelated process never ends the run")
    func promptForUnrelatedProcessIsIgnored() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: """
            #!/bin/sh
            sleep 1
            printf '%s' '\(StubAgentCLI.validWorkerJSON)' > "$1"
            """)
        defer { fixture.cleanUp() }
        // launchd: alive, and never a descendant of the run.
        let watch = StubPromptWatch(repeats: true) { 1 }

        let report = try await process(with: watch).run(fixture.launch(timeout: .seconds(40)))

        #expect(report.end == .exited(status: 0))
        guard case .completed = report.outcome else {
            Issue.record("expected .completed, got \(report.outcome)")
            return
        }
        #expect(await watch.stopped)
    }

    @Test("A run whose spawn fails still stops its watch")
    func spawnFailureStopsWatch() async throws {
        let fixture = try StubAgentCLI.makeFixture(script: "#!/bin/sh\nexit 0\n")
        defer { fixture.cleanUp() }
        var launch = fixture.launch()
        launch.executable = fixture.tempDir.appendingPathComponent("missing").path
        let watch = StubPromptWatch(repeats: true) { nil }

        await #expect(throws: AgentCLILaunchError.self) {
            try await process(with: watch).run(launch)
        }
        #expect(await watch.stopped)
    }
}

/// The real unified-log watch, against a real Keychain prompt, so it runs only when asked:
/// `YH_LIVE_KEYCHAIN_PROMPT=1 swift test --filter LiveKeychainPromptTests`. Warning: ending the run kills
/// the `security` client, but on macOS 27 the dialog stays on screen until someone dismisses it (measured
/// 2026-10-18). Click Deny. Its item is already deleted, but Always Allow could add `/usr/bin/security` to
/// that item's ACL.
@Suite(
    "Agent CLI process: a live Keychain prompt",
    .enabled(if: ProcessInfo.processInfo.environment["YH_LIVE_KEYCHAIN_PROMPT"] == "1"),
    .timeLimit(.minutes(1))
)
struct LiveKeychainPromptTests {
    static let service = "dev.yellowhammer.probe"

    @Test("A security read of an item that trusts no application ends the run as prompt-blocked")
    func liveKeychainPromptEndsRun() async throws {
        let account = "prompt-probe-\(UUID().uuidString.prefix(8).lowercased())"
        // `-T ""` trusts no application, so a `-w` read prompts.
        let added = Self.security(["add-generic-password", "-s", Self.service, "-a", account, "-w", account, "-T", ""])
        try #require(added == 0)
        defer { _ = Self.security(["delete-generic-password", "-s", Self.service, "-a", account]) }

        let fixture = try StubAgentCLI.makeFixture(script: """
            #!/bin/sh
            /usr/bin/security find-generic-password -s \(Self.service) -a \(account) -w > /dev/null 2>&1 &
            echo $! > "$2/client"
            wait
            """)
        defer { fixture.cleanUp() }

        let clock = ContinuousClock()
        let start = clock.now
        let report = try await AgentCLIProcess().run(fixture.launch(timeout: .seconds(45)))
        let elapsed = clock.now - start

        let client = try #require(pid(inFile: fixture.scratch.appendingPathComponent("client")))
        guard case .promptBlocked(let detail, _) = report.end else {
            Issue.record("expected .promptBlocked, got \(report.end)")
            return
        }
        print("live Keychain prompt: ended in \(elapsed) — \(detail)")
        #expect(detail == "Keychain prompt for /usr/bin/security (pid \(client)), item \(Self.service)")
        #expect(elapsed < .seconds(10))
    }

    private static func security(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
