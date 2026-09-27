import Darwin
import Foundation
import ProcessTestSupport
@testable import Repositories
import Testing

@Suite("Process fencing tests", .timeLimit(.minutes(1)))
struct ProcessFencerTests {

    @Test("A process with cwd inside the Worktree is a holder and is killed by fence")
    func cwdHolderIsFencedAndKilled() async throws {
        let worktree = try Self.makeTempDir(name: "cwd-holder-1")
        defer { try? FileManager.default.removeItem(at: worktree) }

        let child = try Self.launchSleep(currentDirectory: worktree)
        defer { child.terminateAndReap() }
        try await Task.sleep(for: .milliseconds(150))

        let fencer = ProcessFencer()
        let found = fencer.holders(of: worktree.path)
        let holder = try #require(found.first { $0.pid == child.pid })
        guard case .workingDirectory = holder.reason else {
            Issue.record("expected .workingDirectory, got \(holder.reason)")
            return
        }

        let outcome = await fencer.fence(worktreePath: worktree.path)
        guard case .quiescent(let killed) = outcome else {
            Issue.record("expected .quiescent, got \(outcome)")
            return
        }
        #expect(killed.contains { $0.pid == child.pid })

        let status = await child.waitForExit()
        #expect(status == .signalled(SIGKILL))

        #expect(fencer.holders(of: worktree.path).isEmpty)
    }

    @Test("fence from a cancelled task still sleeps between sweeps of the process table")
    func cancelledFenceDoesNotBusyWait() async throws {
        let worktree = try Self.makeTempDir(name: "cancelled-fence")
        defer { try? FileManager.default.removeItem(at: worktree) }

        let child = try Self.launchSleep(currentDirectory: worktree)
        defer { child.terminateAndReap() }
        try await Task.sleep(for: .milliseconds(150))

        let sweeps = SweepCounter()
        let fencer = ProcessFencer(
            pollInterval: .milliseconds(50),
            quiescenceTimeout: .milliseconds(500),
            sendSignal: { _, _ in 0 },
            didSweep: { sweeps.increment() }
        )
        let fence = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await fencer.fence(worktreePath: worktree.path)
        }
        let outcome = await fence.value

        guard case .notQuiescent = outcome else {
            Issue.record("expected .notQuiescent, got \(outcome)")
            return
        }
        // 500 ms / 50 ms = 10 polls, plus the first and last sweeps. A busy-wait makes many more.
        #expect(sweeps.count <= 15)
    }

    @Test("A process with an open file inside the Worktree, but cwd elsewhere, is a holder killed by fence")
    func openFileHolderIsFencedAndKilled() async throws {
        let worktree = try Self.makeTempDir(name: "openfile-holder-2")
        defer { try? FileManager.default.removeItem(at: worktree) }

        let watchedFile = worktree.appendingPathComponent("watched.log")
        #expect(FileManager.default.createFile(atPath: watchedFile.path, contents: Data()))
        let resolvedFile = Self.realResolve(watchedFile.path)

        let child = try Self.launchTailF(file: watchedFile, currentDirectory: FileManager.default.temporaryDirectory)
        defer { child.terminateAndReap() }
        try await Task.sleep(for: .milliseconds(150))

        let fencer = ProcessFencer()
        let found = fencer.holders(of: worktree.path)
        let holder = try #require(found.first { $0.pid == child.pid })
        guard case .openFile(let path) = holder.reason else {
            Issue.record("expected .openFile, got \(holder.reason)")
            return
        }
        #expect(path == resolvedFile)

        let outcome = await fencer.fence(worktreePath: worktree.path)
        guard case .quiescent(let killed) = outcome else {
            Issue.record("expected .quiescent, got \(outcome)")
            return
        }
        #expect(killed.contains { $0.pid == child.pid })

        let status = await child.waitForExit()
        #expect(status == .signalled(SIGKILL))

        #expect(fencer.holders(of: worktree.path).isEmpty)
    }

    @Test("A process whose cwd is a sibling directory sharing a name prefix is not a holder")
    func siblingWithSharedPrefixIsNotAHolder() async throws {
        let worktree = try Self.makeTempDir(name: "prefix-3")
        defer { try? FileManager.default.removeItem(at: worktree) }
        let sibling = URL(fileURLWithPath: worktree.path + "2")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sibling) }

        let child = try Self.launchSleep(currentDirectory: sibling)
        defer { child.terminateAndReap() }
        try await Task.sleep(for: .milliseconds(150))

        let fencer = ProcessFencer()
        let found = fencer.holders(of: worktree.path)
        #expect(found.contains { $0.pid == child.pid } == false)
        #expect(child.isRunning)
    }

    @Test("fence on a clean Worktree returns .quiescent immediately with nothing killed")
    func cleanWorktreeIsImmediatelyQuiescent() async throws {
        let worktree = try Self.makeTempDir(name: "clean-4")
        defer { try? FileManager.default.removeItem(at: worktree) }

        let fencer = ProcessFencer()
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await fencer.fence(worktreePath: worktree.path)
        let elapsed = clock.now - start

        guard case .quiescent(let killed) = outcome else {
            Issue.record("expected .quiescent, got \(outcome)")
            return
        }
        #expect(killed.isEmpty)
        // Well under the default quiescenceTimeout (10s), proving fence() did not wait it out.
        // Not a tighter bound: under `swift test --parallel` for the whole package, unrelated
        // suites' concurrent process spawns can starve Swift concurrency's cooperative thread
        // pool, delaying even a single 50ms poll well past a sub-second bound.
        #expect(elapsed < .seconds(5))
    }

    @Test("fence on a nonexistent path returns .pathMissing without touching the process table")
    func nonexistentPathIsPathMissing() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("yh-missing-\(UUID().uuidString)")

        let fencer = ProcessFencer()
        let outcome = await fencer.fence(worktreePath: missing.path)

        guard case .pathMissing = outcome else {
            Issue.record("expected .pathMissing, got \(outcome)")
            return
        }
    }

    @Test("fence returns only once the Worktree is quiescent, not before")
    func fenceReturnsOnlyOnceQuiescent() async throws {
        let worktree = try Self.makeTempDir(name: "quiescence-6")
        defer { try? FileManager.default.removeItem(at: worktree) }

        let child = try Self.launchSleep(currentDirectory: worktree)
        defer { child.terminateAndReap() }
        try await Task.sleep(for: .milliseconds(150))

        let fencer = ProcessFencer(pollInterval: .milliseconds(50), quiescenceTimeout: .seconds(2))
        let outcome = await fencer.fence(worktreePath: worktree.path)

        guard case .quiescent = outcome else {
            Issue.record("expected .quiescent, got \(outcome)")
            return
        }
        #expect(fencer.holders(of: worktree.path).isEmpty)

        let status = await child.waitForExit()
        #expect(status == .signalled(SIGKILL))
    }

    // MARK: - Fixtures

    private static func makeTempDir(name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yh-fencer-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func realResolve(_ path: String) -> String {
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard let resolved = realpath(path, &buffer) else { return path }
        return String(cString: resolved)
    }

    private static func launchSleep(currentDirectory: URL, seconds: Int = 300) throws -> SpawnedChild {
        try SpawnedChild.spawn(
            executable: "/bin/sleep", arguments: ["\(seconds)"], currentDirectory: currentDirectory
        )
    }

    private static func launchTailF(file: URL, currentDirectory: URL) throws -> SpawnedChild {
        try SpawnedChild.spawn(
            executable: "/usr/bin/tail", arguments: ["-f", file.path], currentDirectory: currentDirectory
        )
    }
}

private final class SweepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func increment() { lock.withLock { value += 1 } }
}
