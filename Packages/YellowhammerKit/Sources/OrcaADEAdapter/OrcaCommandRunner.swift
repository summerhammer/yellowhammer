import Foundation
import Subprocess
import System

/// Runs the `orca` CLI. The concrete runner shells out through swift-subprocess; tests substitute a stub so no
/// suite but the opt-in scratch tests depends on the real binary.
public protocol OrcaCommandRunner: Sendable {
    func run(_ arguments: [String]) async throws -> OrcaCommandOutput
}

/// The result of one `orca` invocation.
public struct OrcaCommandOutput: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Concrete runner that invokes the `orca` executable through swift-subprocess.
///
/// The executable is found on `PATH`, falling back to `/usr/local/bin/orca`. Modelled on
/// `Repositories/GitRunner`: awaiting the child parks no cooperative-pool thread, and a process timeout
/// tears it down. Cancelling the calling task tears the child down too.
public struct ProcessOrcaCommandRunner: OrcaCommandRunner {
    public let executablePath: String
    public let timeout: TimeInterval

    public init(executablePath: String? = nil, timeout: TimeInterval = 60) {
        self.executablePath = executablePath ?? Self.findOrcaExecutable()
        self.timeout = timeout
    }

    /// Finds the `orca` executable on the current system, searching PATH or defaulting to
    /// `/usr/local/bin/orca`.
    public static func findOrcaExecutable() -> String {
        if let pathVar = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathVar.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("orca").path
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return "/usr/local/bin/orca"
    }

    public func run(_ arguments: [String]) async throws -> OrcaCommandOutput {
        enum Race: Sendable {
            case finished(OrcaCommandOutput)
            case timedOut
            case idle
        }
        let timeout = timeout
        return try await withThrowingTaskGroup(of: Race.self) { group in
            group.addTask { .finished(try await execute(arguments)) }
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(timeout))
                    return .timedOut
                } catch {
                    return .idle
                }
            }
            var output: OrcaCommandOutput?
            var timedOut = false
            while let outcome = try await group.next() {
                switch outcome {
                case .finished(let finished):
                    output = finished
                    group.cancelAll()
                case .timedOut:
                    timedOut = true
                    group.cancelAll()
                case .idle:
                    break
                }
            }
            guard let output else { throw CancellationError() }
            guard timedOut else { return output }
            return OrcaCommandOutput(
                exitCode: 124,
                stdout: output.stdout,
                stderr: output.stderr.isEmpty ? "orca command timed out after \(timeout)s" : output.stderr
            )
        }
    }

    private func execute(_ arguments: [String]) async throws -> OrcaCommandOutput {
        var platformOptions = PlatformOptions()
        // SIGTERM, then (implicitly) SIGKILL after 50 ms.
        platformOptions.teardownSequence = [.send(signal: .terminate, allowedDurationToNextStep: .milliseconds(50))]
        let result = try await Subprocess.run(
            .path(FilePath(executablePath)),
            arguments: Arguments(arguments),
            platformOptions: platformOptions,
            input: .none,
            output: .bytes(limit: 64 * 1024 * 1024),
            error: .bytes(limit: 1024 * 1024)
        )
        let exitCode: Int32
        switch result.terminationStatus {
        case .exited(let code), .signaled(let code):
            exitCode = code
        }
        return OrcaCommandOutput(
            exitCode: exitCode,
            stdout: String(validating: result.standardOutput, as: UTF8.self) ?? "",
            stderr: String(validating: result.standardError, as: UTF8.self) ?? ""
        )
    }
}
