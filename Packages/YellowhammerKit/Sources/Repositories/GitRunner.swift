import Foundation

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

/// Concrete runner that invokes the `git` executable via Foundation `Process`.
///
/// Passes ambient environment variables by default and supports transport and process timeouts.
public struct GitRunner: Sendable {
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

    /// Asynchronously runs git with the given arguments.
    public func run(
        _ arguments: [String],
        workingDirectory: String? = nil,
        timeout: TimeInterval? = nil
    ) async -> GitCommandResult {
        await Task.detached {
            self.runSync(arguments, workingDirectory: workingDirectory, timeout: timeout)
        }.value
    }

    /// Synchronously runs git with the given arguments and optional timeout.
    public func runSync(
        _ arguments: [String],
        workingDirectory: String? = nil,
        timeout: TimeInterval? = nil
    ) -> GitCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        if let workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return GitCommandResult(
                exitCode: -1,
                stdout: "",
                stderr: "Failed to launch git: \(error.localizedDescription)"
            )
        }

        var timedOut = false
        if let timeout {
            let start = Date()
            while process.isRunning && Date().timeIntervalSince(start) < timeout {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                timedOut = true
                process.terminate()
                Thread.sleep(forTimeInterval: 0.05)
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let exitCode = timedOut ? 124 : process.terminationStatus
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        var stderr = String(data: stderrData, encoding: .utf8) ?? ""
        if timedOut && stderr.isEmpty {
            stderr = "Git command timed out after \(timeout ?? 0)s"
        }

        return GitCommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }
}
