import Config
import Foundation
import Testing

/// A child process that flocks a path exclusively and holds it for `holdSeconds`, printing `"locked"`
/// to a pipe the moment it has the lock — so the test can wait for the lock to actually be held before
/// asserting anything about a competing `withLock` in this process.
private final class LockingChild: @unchecked Sendable {
    private let process: Process
    private let outputPipe = Pipe()

    init(lockPath: String, holdSeconds: Double) {
        process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            """
            import fcntl, sys, time
            f = open(sys.argv[1], "a")
            fcntl.flock(f, fcntl.LOCK_EX)
            print("locked", flush=True)
            time.sleep(float(sys.argv[2]))
            """,
            lockPath, String(holdSeconds)
        ]
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
    }

    /// Starts the child and blocks (with a bounded timeout) until it reports holding the lock.
    func startAndWaitUntilLocked(timeout: Duration = .seconds(5)) throws {
        try process.run()
        let handle = outputPipe.fileHandleForReading
        let deadline = ContinuousClock.now + timeout
        var buffer = Data()
        while !buffer.contains(UInt8(ascii: "\n")) {
            guard ContinuousClock.now < deadline else {
                throw TestFailure("the locking child never reported holding the lock")
            }
            let chunk = handle.availableData
            if chunk.isEmpty {
                usleep(5_000)
                continue
            }
            buffer.append(chunk)
        }
    }

    func terminateAndWait() {
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@Suite("MachineLock (P17.4, Linear App Installation Ruling items 3 and 11)")
struct MachineLockTests {
    private func temporaryLockPath() -> URL {
        FileManager.default.temporaryDirectory
            .appending(component: "yh-machine-lock-\(UUID().uuidString).lock", directoryHint: .notDirectory)
    }

    @Test("withLock blocks until a sibling process' flock on the same file is released")
    func blocksAcrossProcesses() async throws {
        let path = temporaryLockPath()
        let child = LockingChild(lockPath: path.path, holdSeconds: 1.0)
        try child.startAndWaitUntilLocked()
        defer { child.terminateAndWait() }

        let lock = MachineLock(fileURL: path)
        let start = ContinuousClock.now
        try await lock.withLock {}
        let elapsed = start.duration(to: .now)

        // Generous bounds: the child holds the lock ~1.0 s; this process' withLock must have waited
        // for (most of) that, not raced past it.
        #expect(elapsed >= .milliseconds(800))
        #expect(elapsed < .seconds(4))
    }

    @Test("A body that throws still releases the lock: a second withLock enters immediately")
    func bodyThrowingStillReleases() async throws {
        let path = temporaryLockPath()
        let lock = MachineLock(fileURL: path)
        struct BodyFailure: Error {}

        do {
            try await lock.withLock { throw BodyFailure() }
            Issue.record("expected a throw")
        } catch .bodyFailed {
            // Expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        let start = ContinuousClock.now
        try await lock.withLock {}
        #expect(start.duration(to: .now) < .milliseconds(200))
    }

    @Test("An unopenable lock path throws rather than running the body unlocked")
    func unopenablePathThrows() async throws {
        // A path under a file (not a directory) can never be created.
        let notADirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-machine-lock-file-\(UUID().uuidString)", directoryHint: .notDirectory)
        try Data().write(to: notADirectory)
        defer { try? FileManager.default.removeItem(at: notADirectory) }
        let path = notADirectory.appending(component: "nested", directoryHint: .notDirectory)
            .appending(component: "linear-token.lock", directoryHint: .notDirectory)
        let lock = MachineLock(fileURL: path)
        var bodyRan = false

        await #expect(throws: MachineLockError.self) {
            try await lock.withLock { bodyRan = true }
        }
        #expect(!bodyRan)
    }

    @Test("The synchronous variant also blocks across processes and releases on throw")
    func synchronousVariant() throws {
        let path = temporaryLockPath()
        let child = LockingChild(lockPath: path.path, holdSeconds: 1.0)
        try child.startAndWaitUntilLocked()
        defer { child.terminateAndWait() }

        let lock = MachineLock(fileURL: path)
        let start = ContinuousClock.now
        try lock.withLock {}
        #expect(start.duration(to: .now) >= .milliseconds(800))
    }
}
