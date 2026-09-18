import Domain
import Foundation
import Synchronization

/// The engine-run Check (graph-execution/gate-a-card-on-the-repository-check, roadmap P8.5): the command a
/// repository declared, run by the engine in the Card's Worktree between the worker and the reviewer. A
/// model's own "the tests pass" never stands in for it.
///
/// The command runs as `/bin/sh -c <command>` with the Worktree as its current directory and this process's
/// environment. Its stdout and stderr share one pipe, so the output stays interleaved in the order it was
/// printed. Exit status 0 passes; any other status, command-not-found and death by a signal included, fails.
/// A shell that cannot be launched, or a Worktree that is not there, is an engine fault and throws
/// ``WorktreeCheckError`` — never a failed Check, and never a pass.
///
/// Accepted cost (risk R6): a flaky Check blocks a Card that nothing was wrong with, and with a round
/// budget of two it does so quickly. The engine runs the Check exactly as declared and does not retry it.
///
/// There is no timeout, because the spec rules none and no config key is invented for one: a hung Check
/// holds the Card's Lease until the Lease is lost. Whether a Check needs a timeout is an open spec question.
public struct WorktreeCheck: RepositoryCheckRunning {
    /// Retained output is the last 64 KiB: the tail is where a failing Check prints what went wrong.
    public static let defaultOutputLimit = 64 * 1024

    /// The most output bytes kept; earlier bytes are dropped and counted in a marker line.
    public let outputLimit: Int

    public init(outputLimit: Int = WorktreeCheck.defaultOutputLimit) {
        self.outputLimit = outputLimit
    }

    public func run(repository: String, check: Check, worktreePath: String) async throws -> RepositoryCheckResult {
        guard case .command(let command) = check else {
            return .declaredNone
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: worktreePath, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            throw WorktreeCheckError.worktreeMissing(repository: repository, path: worktreePath)
        }
        try Task.checkCancellation()

        let child = CheckChild(command: command, directory: worktreePath, outputLimit: outputLimit)
        do {
            try child.launch()
        } catch {
            throw WorktreeCheckError.shellNotLaunched(repository: repository, reason: "\(error)")
        }
        let finished = await child.finished()
        if finished.cancelled {
            throw CancellationError()
        }
        return finished.exitStatus == 0
            ? .passed(output: finished.output)
            : .failed(output: finished.output, exitStatus: finished.exitStatus)
    }
}

/// An engine fault of the Check runner, not an outcome of the Check: the Card run stops.
public enum WorktreeCheckError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The Worktree the Check was to run in does not exist as a directory.
    case worktreeMissing(repository: String, path: String)
    /// `/bin/sh` could not be launched.
    case shellNotLaunched(repository: String, reason: String)

    public var description: String {
        switch self {
        case .worktreeMissing(let repository, let path):
            "the Worktree for repository '\(repository)' is not a directory: \(path)"
        case .shellNotLaunched(let repository, let reason):
            "the shell for repository '\(repository)'s Check could not be launched: \(reason)"
        }
    }
}

/// One running Check: the child process, its pipe drained as it prints, and the wait for both its exit and
/// the end of its output. Cancelling the waiting task terminates the child and ends the wait at once.
private final class CheckChild: @unchecked Sendable {
    struct Finished {
        let output: String
        let exitStatus: Int32
        let cancelled: Bool
    }

    private struct State {
        var tail = Data()
        var dropped = 0
        var endOfOutput = false
        var exitStatus: Int32?
        var launched = false
        var cancelled = false
        var waiter: CheckedContinuation<Void, Never>?

        var isDone: Bool { cancelled || (endOfOutput && exitStatus != nil) }

        /// Keeps at most about twice `limit` bytes, so trimming is amortised; the final trim is exact.
        mutating func append(_ data: Data, limit: Int) {
            tail.append(data)
            if tail.count > limit * 2 {
                dropped += tail.count - limit
                tail = Data(tail.suffix(limit))
            }
        }
    }

    private let process = Process()
    private let pipe = Pipe()
    private let outputLimit: Int
    private let state = Mutex(State())

    init(command: String, directory: String, outputLimit: Int) {
        self.outputLimit = outputLimit
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
    }

    func launch() throws {
        // Drained while the child runs, so a Check printing more than a pipe buffer holds cannot deadlock.
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                update { $0.endOfOutput = true }
            } else {
                update { $0.append(data, limit: outputLimit) }
            }
        }
        process.terminationHandler = { [self] finished in
            // The shell's convention for a command killed by a signal.
            let status = finished.terminationReason == .uncaughtSignal
                ? 128 + finished.terminationStatus : finished.terminationStatus
            update { $0.exitStatus = status }
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        // The parent's copy of the write end must close, or the read end never reaches end of output.
        try? pipe.fileHandleForWriting.close()
        let cancelledEarly = state.withLock { state in
            state.launched = true
            return state.cancelled
        }
        if cancelledEarly { terminate() }
    }

    func finished() async -> Finished {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let alreadyDone = state.withLock { state in
                    if state.isDone { return true }
                    state.waiter = continuation
                    return false
                }
                if alreadyDone { continuation.resume() }
            }
        } onCancel: {
            cancel()
        }
        return state.withLock { state in
            Finished(
                output: Self.render(state, limit: outputLimit), exitStatus: state.exitStatus ?? -1,
                cancelled: state.cancelled
            )
        }
    }

    private func update(_ change: (inout State) -> Void) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            change(&state)
            guard state.isDone, let waiter = state.waiter else { return nil }
            state.waiter = nil
            return waiter
        }
        waiter?.resume()
    }

    private func cancel() {
        let launched = state.withLock { $0.launched }
        update { $0.cancelled = true }
        if launched { terminate() }
        // A grandchild that inherited the pipe may outlive the shell: stop reading rather than wait for it.
        pipe.fileHandleForReading.readabilityHandler = nil
    }

    private func terminate() {
        if process.isRunning { process.terminate() }
    }

    private static func render(_ state: State, limit: Int) -> String {
        var tail = state.tail
        var dropped = state.dropped
        if tail.count > limit {
            dropped += tail.count - limit
            tail = Data(tail.suffix(limit))
        }
        // Lossy on purpose: a cut through a multi-byte scalar, or a Check printing binary, must not lose the
        // rest, which the failable `String(data:encoding:)` would.
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: tail, as: UTF8.self)
        return dropped == 0 ? text : "[… \(dropped) earlier bytes of output dropped]\n" + text
    }
}
