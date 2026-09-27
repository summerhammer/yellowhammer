import Darwin
import Foundation

/// A machine-wide exclusive lock on an empty file (Linear App Installation Ruling, item 3 and 11):
/// every Engine invocation and the app itself share one refresh critical section, so two processes
/// racing to refresh the Installation's rotating refresh token never both succeed — Linear invalidates
/// the old one the moment the new one is issued, so the loser of an unlocked race would be stranded.
///
/// Unlike ``LedgerStore``'s own migration lock, this one never falls back to running unlocked: a lock
/// that cannot be taken must stop the refresh, not let two processes race silently. The file holds no
/// state — nothing is ever written to it; `flock` only needs an inode to hold its lock on.
public struct MachineLock: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// The default location, alongside the rest of Yellowhammer's machine-scoped configuration.
    public static func defaultFileURL(homeDirectory: URL) -> URL {
        homeDirectory.appending(
            components: ".config", "yellowhammer", "linear-token.lock", directoryHint: .notDirectory
        )
    }

    /// Runs `body` while holding the lock, blocking until it is free. Throws — never runs `body`
    /// unlocked — when the lock file's parent cannot be created, the file cannot be opened, or the
    /// underlying `flock` call itself fails for a reason other than blocking (e.g. an interrupted
    /// call is retried once).
    public func withLock<T>(_ body: () throws -> T) throws(MachineLockError) -> T {
        let descriptor = try open()
        defer { close(descriptor) }
        try acquire(descriptor)
        defer { flock(descriptor, LOCK_UN) }
        do {
            return try body()
        } catch {
            throw .bodyFailed(error)
        }
    }

    /// The async variant: the blocking `flock` wait runs on a GCD global queue, off Swift's
    /// cooperative thread pool — `Task.detached` alone only detaches from the parent task, not the
    /// executor, so it would still occupy a pool thread for the whole blocking wait. GCD's queue
    /// overcommits threads, so a waiting invocation never starves other work sharing the pool. The
    /// lock is then held across `body`'s own `await`s (a short refresh HTTP call) by construction —
    /// acquire and release happen on the same underlying file descriptor, opened and closed on this
    /// call's own task.
    public func withLock<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws(MachineLockError) -> T {
        let descriptor = try open()
        defer { close(descriptor) }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try self.acquire(descriptor)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch let error as MachineLockError {
            throw error
        } catch {
            throw .couldNotLock(path: fileURL.path, reason: String(describing: error))
        }
        defer { flock(descriptor, LOCK_UN) }
        do {
            return try await body()
        } catch {
            throw .bodyFailed(error)
        }
    }

    private func open() throws(MachineLockError) -> Int32 {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch {
            throw .couldNotOpen(path: fileURL.path, reason: String(describing: error))
        }
        let descriptor = Darwin.open(fileURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw .couldNotOpen(path: fileURL.path, reason: String(cString: strerror(errno)))
        }
        return descriptor
    }

    /// Blocks until the exclusive lock is held. `flock` is retried once on `EINTR` — a signal
    /// interrupting the blocking wait is not a reason to give up and run unlocked.
    private func acquire(_ descriptor: Int32) throws(MachineLockError) {
        var result = flock(descriptor, LOCK_EX)
        if result != 0, errno == EINTR {
            result = flock(descriptor, LOCK_EX)
        }
        guard result == 0 else {
            throw .couldNotLock(path: fileURL.path, reason: String(cString: strerror(errno)))
        }
    }
}

public enum MachineLockError: Error, Sendable {
    case couldNotOpen(path: String, reason: String)
    case couldNotLock(path: String, reason: String)
    /// `body` itself threw; the lock was still held for its entire run and is released regardless.
    case bodyFailed(any Error)
}

extension MachineLockError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .couldNotOpen(let path, let reason):
            "could not open the Linear token lock file at \(path): \(reason)"
        case .couldNotLock(let path, let reason):
            "could not lock the Linear token lock file at \(path): \(reason)"
        case .bodyFailed(let error):
            String(describing: error)
        }
    }
}
