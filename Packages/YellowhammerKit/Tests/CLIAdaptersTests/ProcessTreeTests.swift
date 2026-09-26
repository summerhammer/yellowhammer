@testable import CLIAdapters
import Darwin
import Foundation
import Testing

/// Exercises ``ProcessTree`` directly, against real spawned processes — never the stub CLI
/// fixtures, which live at a higher level (`AgentCLIProcessEscapeTests`).
@Suite("ProcessTree", .timeLimit(.minutes(1)))
struct ProcessTreeTests {
    /// A script whose top-level invocation forks a direct child (`child`), which itself forks a
    /// grandchild into a brand-new session (`setsid`) — the exact shape a CLI's tool subprocess
    /// escaping into `setsid` produces, two hops down from the leader. Each level writes its own
    /// pid to `<scratch>/child_pid` / `<scratch>/grandchild_pid` before blocking in `sleep`.
    private static let script = """
        #!/bin/sh
        scratch="$1"

        grandchild() {
            echo $$ > "$scratch/grandchild_pid"
            exec sleep 5
        }

        child() {
            echo $$ > "$scratch/child_pid"
            perl -MPOSIX -e 'POSIX::setsid(); exec { $ARGV[0] } @ARGV' "$0" "$scratch" grandchild &
            wait
        }

        case "$2" in
            grandchild)
                grandchild
                ;;
            *)
                child &
                wait
                ;;
        esac
        """

    private struct Fixture {
        let scratch: URL
        let process: Process

        func readPID(_ name: String) -> pid_t? {
            guard let text = try? String(contentsOf: scratch.appendingPathComponent(name), encoding: .utf8) else {
                return nil
            }
            return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        /// Best-effort teardown of every process this fixture may have spawned, even if the test
        /// failed before recording every pid.
        func tearDown() {
            process.terminate()
            for name in ["child_pid", "grandchild_pid"] {
                if let pid = readPID(name) {
                    kill(pid, SIGKILL)
                }
            }
            try? FileManager.default.removeItem(at: scratch.deletingLastPathComponent())
        }
    }

    private func makeFixture() throws -> Fixture {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("yh-processtree-\(UUID().uuidString)")
        let scratch = tempDir.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let scriptPath = tempDir.appendingPathComponent("tree.sh")
        try Self.script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath.path)

        let process = Process()
        process.executableURL = scriptPath
        process.arguments = [scratch.path]
        try process.run()

        return Fixture(scratch: scratch, process: process)
    }

    private static func awaitPID(_ fixture: Fixture, _ name: String, timeout: Duration = .seconds(2)) async -> pid_t? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let pid = fixture.readPID(name) { return pid }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    @Test("descendants(of:) includes a grandchild in a new session, whose pgid differs from the root's")
    func descendantsFindsGrandchildInNewSession() async throws {
        let fixture = try makeFixture()
        defer { fixture.tearDown() }

        let rootPID = fixture.process.processIdentifier
        let grandchildPID = try #require(await Self.awaitPID(fixture, "grandchild_pid"))

        let descendants = ProcessTree.descendants(of: rootPID)
        let grandchild = try #require(descendants.first { $0.pid == grandchildPID })

        let rootIdentity = try #require(ProcessTree.identity(of: rootPID))
        #expect(grandchild.processGroup != rootIdentity.processGroup)
    }

    @Test("signal refuses a TrackedProcess whose start time no longer matches")
    func signalRefusesMismatchedStartTime() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        defer { process.terminate() }

        let pid = process.processIdentifier
        let real = try #require(ProcessTree.identity(of: pid))
        let bogus = ProcessTree.TrackedProcess(
            pid: real.pid, processGroup: real.processGroup, session: real.session, commandName: real.commandName,
            startSeconds: real.startSeconds + 1, startMicroseconds: real.startMicroseconds
        )

        let signalled = ProcessTree.signal(bogus, SIGKILL)

        #expect(signalled == false)
        #expect(kill(pid, 0) == 0)
    }

    @Test("ancestors(of:) walks pbi_ppid up to and including this test process")
    func ancestorsIncludesThisTestProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        defer { process.terminate() }

        let ancestors = ProcessTree.ancestors(of: process.processIdentifier)

        #expect(ancestors.contains(getpid()))
    }

    @Test("identity(of:) carries a session and a non-empty command name")
    func identityCarriesSessionAndCommandName() throws {
        let selfIdentity = try #require(ProcessTree.identity(of: getpid()))
        #expect(selfIdentity.session != 0)
        #expect(!selfIdentity.commandName.isEmpty)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        defer { process.terminate() }

        let child = try #require(ProcessTree.identity(of: process.processIdentifier))
        #expect(!child.commandName.isEmpty)
    }

    @Test("isGone is true once the process has been killed and reaped")
    func isGoneAfterKillAndReap() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()

        let pid = process.processIdentifier
        let tracked = try #require(ProcessTree.identity(of: pid))

        kill(pid, SIGKILL)
        process.waitUntilExit()

        #expect(ProcessTree.isGone(tracked))
    }
}
