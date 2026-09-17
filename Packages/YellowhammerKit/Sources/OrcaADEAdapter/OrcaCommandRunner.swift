import Foundation

/// Runs the `orca` CLI. The concrete runner shells out to `Process`; tests substitute a stub so no
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

/// Concrete runner that invokes the `orca` executable via Foundation `Process`.
///
/// The executable is found on `PATH`, falling back to `/usr/local/bin/orca`. Modelled on
/// `Repositories/GitRunner`: the blocking work runs in `Task.detached`, with a process timeout.
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
        try await Task.detached {
            try self.runSync(arguments)
        }.value
    }

    private func runSync(_ arguments: [String]) throws -> OrcaCommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        var timedOut = false
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
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        let exitCode = timedOut ? 124 : process.terminationStatus
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        var stderr = String(data: stderrData, encoding: .utf8) ?? ""
        if timedOut && stderr.isEmpty {
            stderr = "orca command timed out after \(timeout)s"
        }

        return OrcaCommandOutput(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }
}
