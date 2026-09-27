import Darwin
import Domain
import Foundation
import ProcessTestSupport
@testable import Repositories
import Testing

@Suite("Attributed Worktree fence tests (Normal-Exit Sweep Ruling)", .timeLimit(.minutes(1)))
struct ProcessFencerAttributionTests {

    @Test("A holder whose pid and start time are in the snapshot is killed (rule 1)")
    func rule1PIDAndStartTimeIsKilled() async throws {
        let worktree = try Self.makeTempDir(name: "rule1")
        defer { try? FileManager.default.removeItem(at: worktree) }

        let child = try Self.launchSleep(currentDirectory: worktree)
        defer { child.terminateAndReap() }
        try await Task.sleep(for: .milliseconds(150))

        let identity = try #require(ProcessIdentity.identity(of: child.pid))
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
        #expect(killed.contains { $0.pid == child.pid })

        let status = await child.waitForExit()
        #expect(status == .signalled(SIGKILL))
    }

    @Test("Rule 2: a holder in a recorded group started after dispatch is killed; an unrecorded holder is left alive")
    func rule2PositiveAndNegative() async throws {
        let worktree = try Self.makeTempDir(name: "rule2")
        defer { try? FileManager.default.removeItem(at: worktree) }

        let dispatchedAt = Self.now()
        let grouped = try Self.launchGroupedSleep(currentDirectory: worktree)
        defer { grouped.terminateAndReap() }
        try await Task.sleep(for: .milliseconds(150))

        let ungrouped = try Self.launchSleep(currentDirectory: worktree)
        defer { ungrouped.terminateAndReap() }
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
        #expect(unattributed.contains { $0.pid == ungrouped.pid })
        #expect(!unattributed.first { $0.pid == ungrouped.pid }!.commandName.isEmpty)

        #expect(ungrouped.isRunning)
    }

    @Test("Rule 2 time guard: a holder in a recorded group but started before dispatch is not killed")
    func rule2TimeGuard() async throws {
        let worktree = try Self.makeTempDir(name: "rule2-time")
        defer { try? FileManager.default.removeItem(at: worktree) }

        let grouped = try Self.launchGroupedSleep(currentDirectory: worktree)
        defer { grouped.terminateAndReap() }
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
        defer { shell.terminateAndReap() }
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

    private static func launchSleep(currentDirectory: URL, seconds: Int = 300) throws -> SpawnedChild {
        try SpawnedChild.spawn(
            executable: "/bin/sleep", arguments: ["\(seconds)"], currentDirectory: currentDirectory
        )
    }

    /// A `sleep` spawned as the leader of its own new process group — unlike `Process`, which
    /// shares the runner's group.
    private static func launchGroupedSleep(currentDirectory: URL, seconds: Int = 300) throws -> SpawnedChild {
        try SpawnedChild.spawn(
            executable: "/bin/sleep", arguments: ["\(seconds)"], currentDirectory: currentDirectory,
            newProcessGroup: true
        )
    }

    /// `/bin/sh -c 'sleep 300 & wait'`, group-leadered, so the shell itself and its backgrounded
    /// `sleep` child both hold the Worktree by cwd, but only the shell is ever in the snapshot.
    private static func launchShellWithBackgroundChild(currentDirectory: URL) throws -> SpawnedChild {
        try SpawnedChild.spawn(
            executable: "/bin/sh", arguments: ["-c", "sleep 300 & wait"], currentDirectory: currentDirectory,
            newProcessGroup: true
        )
    }
}
