import Darwin
import Domain
import Foundation
@testable import Repositories
import Testing

@Suite("Attributed Worktree fence tests (Normal-Exit Sweep Ruling)", .timeLimit(.minutes(1)))
struct ProcessFencerAttributionTests {

    @Test("A holder whose pid and start time are in the snapshot is killed (rule 1)")
    func rule1PIDAndStartTimeIsKilled() async throws {
        let worktree = try Self.makeTempDir(name: "rule1")
        defer { try? FileManager.default.removeItem(at: worktree) }

        let process = try Self.launchSleep(currentDirectory: worktree)
        defer { if process.isRunning { process.terminate() } }
        try await Task.sleep(for: .milliseconds(150))

        let identity = try #require(ProcessIdentity.identity(of: process.processIdentifier))
        let snapshot = RunningSnapshot(
            dispatchedAt: ProcessStartTime(seconds: 0, microseconds: 0),
            processes: [
                SnapshotProcess(
                    pid: identity.pid, startTime: identity.startTime, processGroup: identity.processGroup,
                    session: identity.session, commandName: identity.commandName
                )
            ],
            processGroups: [], sessions: []
        )

        let fencer = ProcessFencer()
        let outcome = await fencer.fence(worktreePath: worktree.path, attributedTo: snapshot)
        guard case .quiescent(let killed, _) = outcome else {
            Issue.record("expected .quiescent, got \(outcome)")
            return
        }
        #expect(killed.contains { $0.pid == process.processIdentifier })

        process.waitUntilExit()
        #expect(process.terminationStatus == SIGKILL)
    }

    @Test("Rule 2: a holder in a recorded group started after dispatch is killed; an unrecorded holder is left alive")
    func rule2PositiveAndNegative() async throws {
        let worktree = try Self.makeTempDir(name: "rule2")
        defer { try? FileManager.default.removeItem(at: worktree) }

        let dispatchedAt = Self.now()
        let grouped = try Self.launchGroupedSleep(currentDirectory: worktree)
        defer { Self.cleanUp(grouped) }
        try await Task.sleep(for: .milliseconds(150))

        let ungrouped = try Self.launchSleep(currentDirectory: worktree)
        defer { if ungrouped.isRunning { ungrouped.terminate() } }
        try await Task.sleep(for: .milliseconds(150))

        let groupedIdentity = try #require(ProcessIdentity.identity(of: grouped.pid))
        let snapshot = RunningSnapshot(
            dispatchedAt: dispatchedAt, processes: [],
            processGroups: [groupedIdentity.processGroup], sessions: []
        )

        let fencer = ProcessFencer()
        let outcome = await fencer.fence(worktreePath: worktree.path, attributedTo: snapshot)
        guard case .quiescent(let killed, let unattributed) = outcome else {
            Issue.record("expected .quiescent, got \(outcome)")
            return
        }
        #expect(killed.contains { $0.pid == grouped.pid })
        #expect(unattributed.contains { $0.pid == ungrouped.processIdentifier })
        #expect(!unattributed.first { $0.pid == ungrouped.processIdentifier }!.commandName.isEmpty)

        #expect(ungrouped.isRunning)
        ungrouped.terminate()
        ungrouped.waitUntilExit()
    }

    @Test("Rule 2 time guard: a holder in a recorded group but started before dispatch is not killed")
    func rule2TimeGuard() async throws {
        let worktree = try Self.makeTempDir(name: "rule2-time")
        defer { try? FileManager.default.removeItem(at: worktree) }

        let grouped = try Self.launchGroupedSleep(currentDirectory: worktree)
        defer { Self.cleanUp(grouped) }
        try await Task.sleep(for: .milliseconds(150))
        let dispatchedAt = Self.now()

        let groupedIdentity = try #require(ProcessIdentity.identity(of: grouped.pid))
        let snapshot = RunningSnapshot(
            dispatchedAt: dispatchedAt, processes: [],
            processGroups: [groupedIdentity.processGroup], sessions: []
        )

        let fencer = ProcessFencer()
        let outcome = await fencer.fence(worktreePath: worktree.path, attributedTo: snapshot)
        guard case .quiescent(let killed, let unattributed) = outcome else {
            Issue.record("expected .quiescent, got \(outcome)")
            return
        }
        #expect(!killed.contains { $0.pid == grouped.pid })
        #expect(unattributed.contains { $0.pid == grouped.pid })

        #expect(ProcessIdentity.identity(of: grouped.pid) != nil)
    }

    @Test("Rule 3: a holder whose parent is attributed by rule 1 is killed, even though it is not itself snapshotted")
    func rule3TransitiveViaParent() async throws {
        let worktree = try Self.makeTempDir(name: "rule3")
        defer { try? FileManager.default.removeItem(at: worktree) }

        let shell = try Self.launchShellWithBackgroundChild(currentDirectory: worktree)
        defer { Self.cleanUp(shell) }
        try await Task.sleep(for: .milliseconds(200))

        let shellIdentity = try #require(ProcessIdentity.identity(of: shell.pid))
        let snapshot = RunningSnapshot(
            dispatchedAt: ProcessStartTime(seconds: 0, microseconds: 0),
            processes: [
                SnapshotProcess(
                    pid: shellIdentity.pid, startTime: shellIdentity.startTime,
                    processGroup: shellIdentity.processGroup, session: shellIdentity.session,
                    commandName: shellIdentity.commandName
                )
            ],
            processGroups: [], sessions: []
        )

        let fencer = ProcessFencer()
        let outcome = await fencer.fence(worktreePath: worktree.path, attributedTo: snapshot)
        guard case .quiescent(let killed, _) = outcome else {
            Issue.record("expected .quiescent, got \(outcome)")
            return
        }
        // Both the shell (cwd holder, rule 1) and the sleep child (cwd holder via rule 3) are killed.
        #expect(killed.contains { $0.pid == shell.pid })
        #expect(killed.count >= 2)
    }

    @Test("fence(attributedTo:) on a nonexistent path returns .pathMissing")
    func pathMissing() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("yh-missing-\(UUID().uuidString)")
        let snapshot = RunningSnapshot(
            dispatchedAt: ProcessStartTime(seconds: 0, microseconds: 0), processes: [], processGroups: [],
            sessions: []
        )

        let fencer = ProcessFencer()
        let outcome = await fencer.fence(worktreePath: missing.path, attributedTo: snapshot)
        guard case .pathMissing = outcome else {
            Issue.record("expected .pathMissing, got \(outcome)")
            return
        }
    }

    // MARK: - Fixtures

    private static func now() -> ProcessStartTime {
        var tv = timeval()
        gettimeofday(&tv, nil)
        return ProcessStartTime(seconds: UInt64(tv.tv_sec), microseconds: UInt64(tv.tv_usec))
    }

    private static func makeTempDir(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yh-attr-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func launchSleep(currentDirectory: URL, seconds: Int = 300) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["\(seconds)"]
        process.currentDirectoryURL = currentDirectory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// A `sleep` spawned via `posix_spawn` with `POSIX_SPAWN_SETPGROUP`/`setpgroup(0)`, so it is
    /// the leader of its own new process group — unlike `Process`, which shares the runner's group.
    private struct GroupedProcess {
        let pid: pid_t
    }

    private static func launchGroupedSleep(currentDirectory: URL, seconds: Int = 300) throws -> GroupedProcess {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addchdir(&fileActions, currentDirectory.path)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        let executable = "/bin/sleep"
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(executable), strdup("\(seconds)"), nil]
        defer { argv.forEach { free($0) } }
        var envp: [UnsafeMutablePointer<CChar>?] = [nil]

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &fileActions, &attr, &argv, &envp)
        guard rc == 0 else { throw TestSetupError.spawnFailed(rc) }
        return GroupedProcess(pid: pid)
    }

    /// `/bin/sh -c 'sleep 300 & wait'`, group-leadered, so the shell itself and its backgrounded
    /// `sleep` child both hold the Worktree by cwd, but only the shell is ever in the snapshot.
    private static func launchShellWithBackgroundChild(currentDirectory: URL) throws -> GroupedProcess {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_addchdir(&fileActions, currentDirectory.path)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        let executable = "/bin/sh"
        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(executable), strdup("-c"), strdup("sleep 300 & wait"), nil
        ]
        defer { argv.forEach { free($0) } }
        var envp: [UnsafeMutablePointer<CChar>?] = [nil]

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &fileActions, &attr, &argv, &envp)
        guard rc == 0 else { throw TestSetupError.spawnFailed(rc) }
        return GroupedProcess(pid: pid)
    }

    private static func cleanUp(_ process: GroupedProcess) {
        kill(-process.pid, SIGKILL)
        var status: Int32 = 0
        waitpid(process.pid, &status, 0)
    }

    private enum TestSetupError: Error {
        case spawnFailed(Int32)
    }
}
