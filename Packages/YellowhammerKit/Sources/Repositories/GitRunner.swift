import Foundation
import Subprocess
import System

/// The result of running a git command.
public struct GitCommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var isSuccess: Bool { exitCode == 0 }

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Concrete runner that invokes the `git` executable through swift-subprocess.
///
/// Passes ambient environment variables by default and supports transport and process timeouts. Awaiting
/// a child parks no cooperative-pool thread: Subprocess spawns off the pool, observes exit on its own
/// monitor thread and drains both pipes as git prints, so large output cannot deadlock the child.
public struct GitRunner: Sendable {
    /// Collected stdout is capped here; a `git` printing more is reported as a failed result.
    static let outputLimit = 64 * 1024 * 1024
    /// Collected stderr is capped here.
    static let errorLimit = 1024 * 1024

    public let executablePath: String
    public let environment: [String: String]

    public init(
        executablePath: String? = nil,
        environment: [String: String]? = nil
    ) {
        self.executablePath = executablePath ?? Self.findGitExecutable()
        self.environment = environment ?? ProcessInfo.processInfo.environment
    }

    /// Finds the `git` executable on the current system, searching PATH or defaulting to `/usr/bin/git`.
    public static func findGitExecutable() -> String {
        if let pathVar = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathVar.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("git").path
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return "/usr/bin/git"
    }

    /// Asynchronously runs git with the given arguments and optional timeout. Never throws: a launch
    /// failure, an output over the cap or any other error is a result with exit code -1.
    ///
    /// The call is cancellable. Cancelling the calling task tears git down (SIGTERM, then SIGKILL after
    /// 50 ms) and returns a failed result, with the signal number as the exit code; only a timeout that
    /// actually fired reports 124.
    public func run(
        _ arguments: [String],
        workingDirectory: String? = nil,
        timeout: TimeInterval? = nil
    ) async -> GitCommandResult {
        enum Race: Sendable {
            case finished(GitCommandResult)
            case timedOut
            case idle
        }
        return await withTaskGroup(of: Race.self) { group in
            group.addTask { .finished(await execute(arguments, workingDirectory: workingDirectory)) }
            if let timeout {
                group.addTask {
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                        return .timedOut
                    } catch {
                        return .idle
                    }
                }
            }
            var result = GitCommandResult(exitCode: -1, stdout: "", stderr: "git did not run")
            var timedOut = false
            for await outcome in group {
                switch outcome {
                case .finished(let finished):
                    result = finished
                    group.cancelAll()
                case .timedOut:
                    timedOut = true
                    group.cancelAll()
                case .idle:
                    break
                }
            }
            guard timedOut else { return result }
            return GitCommandResult(
                exitCode: 124,
                stdout: result.stdout,
                stderr: result.stderr.isEmpty ? "Git command timed out after \(timeout ?? 0)s" : result.stderr
            )
        }
    }

    private func execute(_ arguments: [String], workingDirectory: String?) async -> GitCommandResult {
        var platformOptions = PlatformOptions()
        // The same escalation as before: SIGTERM, then (implicitly) SIGKILL after 50 ms.
        platformOptions.teardownSequence = [.send(signal: .terminate, allowedDurationToNextStep: .milliseconds(50))]
        // A full replacement, never `.inherit`: FeatureBranchPusher relies on it for its GIT_CONFIG_* handling.
        let fullEnvironment = Environment.custom(
            Dictionary(uniqueKeysWithValues: environment.map { (Environment.Key(stringLiteral: $0.key), $0.value) })
        )
        do {
            let result = try await Subprocess.run(
                .path(FilePath(executablePath)),
                arguments: Arguments(arguments),
                environment: fullEnvironment,
                workingDirectory: workingDirectory.map { FilePath($0) },
                platformOptions: platformOptions,
                input: .none,
                output: .bytes(limit: Self.outputLimit),
                error: .bytes(limit: Self.errorLimit)
            )
            let exitCode: Int32
            switch result.terminationStatus {
            case .exited(let code), .signaled(let code):
                exitCode = code
            }
            // Collected as bytes and decoded strictly: non-UTF-8 output stays an empty string, as before.
            return GitCommandResult(
                exitCode: exitCode,
                stdout: String(validating: result.standardOutput, as: UTF8.self) ?? "",
                stderr: String(validating: result.standardError, as: UTF8.self) ?? ""
            )
        } catch let error as SubprocessError
            where [.spawnFailed, .executableNotFound, .failedToChangeWorkingDirectory].contains(error.code) {
            return GitCommandResult(exitCode: -1, stdout: "", stderr: "Failed to launch git: \(error)")
        } catch {
            return GitCommandResult(exitCode: -1, stdout: "", stderr: "git failed: \(error)")
        }
    }
}
