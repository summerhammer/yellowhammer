import Domain
import Foundation
import Subprocess
import System

/// The engine-run Check (graph-execution/gate-a-card-on-the-repository-check, roadmap P8.5): the command a
/// repository declared, run by the engine in the Card's Worktree between the worker and the reviewer. A
/// model's own "the tests pass" never stands in for it.
///
/// The command runs as `/bin/sh -c <command>` with the Worktree as its current directory and this process's
/// environment. Its stdout and stderr share one pipe (`error: .combinedWithOutput`), so the output stays
/// interleaved in the order it was printed. Exit status 0 passes; any other status, command-not-found and death by a signal included, fails.
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

        var platformOptions = PlatformOptions()
        // Cancellation sends SIGTERM to the shell, as before. Subprocess always ends a teardown with SIGKILL, so a
        // Check that ignores SIGTERM is now killed after 3 s; the hand-rolled runner had no such escalation.
        platformOptions.teardownSequence = [.send(signal: .terminate, allowedDurationToNextStep: .seconds(3))]
        let outputLimit = outputLimit
        let result: ExecutionResult<OutputTail, SequenceOutput, CombinedErrorOutput>
        do {
            result = try await Subprocess.run(
                .path("/bin/sh"),
                arguments: ["-c", command],
                workingDirectory: FilePath(worktreePath),
                platformOptions: platformOptions,
                input: .none,
                output: .sequence,
                error: .combinedWithOutput
            ) { execution in
                // Drained while the child runs, so a Check printing more than a pipe buffer holds cannot deadlock.
                var tail = OutputTail()
                for try await buffer in execution.standardOutput {
                    buffer.withUnsafeBytes { tail.append(Data($0), limit: outputLimit) }
                }
                return tail
            }
        } catch let error as SubprocessError
            where [.spawnFailed, .executableNotFound, .failedToChangeWorkingDirectory].contains(error.code) {
            throw WorktreeCheckError.shellNotLaunched(repository: repository, reason: "\(error)")
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw WorktreeCheckError.shellNotLaunched(repository: repository, reason: "\(error)")
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        let exitStatus: Int32
        switch result.terminationStatus {
        case .exited(let code):
            exitStatus = code
        case .signaled(let signal):
            // The shell's convention for a command killed by a signal.
            exitStatus = 128 + signal
        }
        let output = result.closureResult.render(limit: outputLimit)
        return exitStatus == 0 ? .passed(output: output) : .failed(output: output, exitStatus: exitStatus)
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

/// The tail of a Check's output: at most the last `limit` bytes, and a count of the bytes dropped before them.
private struct OutputTail: Sendable {
    private var tail = Data()
    private var dropped = 0

    /// Keeps at most about twice `limit` bytes, so trimming is amortised; ``render(limit:)`` trims exactly.
    mutating func append(_ data: Data, limit: Int) {
        tail.append(data)
        if tail.count > limit * 2 {
            dropped += tail.count - limit
            tail = Data(tail.suffix(limit))
        }
    }

    func render(limit: Int) -> String {
        var tail = tail
        var dropped = dropped
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
