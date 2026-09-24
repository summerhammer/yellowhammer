import Foundation

/// Runs the bundled `yh` non-interactively and streams its merged stdout/stderr. The app never does the
/// Board work itself (ADR-001; the app links only Domain and Config) — this is the seam the Setup wizard
/// runs `SetupInvocation`'s argument vectors against.
@MainActor
final class SetupEngine {
    /// The launch argument naming a stub script to run instead of the bundled `yh`, for UI tests only
    /// (`-YellowhammerEngineStub <path>`): the app runs `/bin/sh <path> <arguments>`, so the only thing
    /// ever exec'd directly is `/bin/sh`, a system binary — never a file the (sandboxed) UI test runner
    /// wrote into its own container, which the app cannot exec (`Process.run()` on such a file fails with
    /// EPERM whatever its permissions). Only the argument domain is read,
    /// exactly the way ``ConfigurationDirectory/argument`` is, so it cannot persist through
    /// `defaults write`.
    static let stubArgument = "YellowhammerEngineStub"

    enum RunError: Error, CustomStringConvertible {
        case executableNotFound
        case launchFailed(String)

        var description: String {
            switch self {
            case .executableNotFound:
                "yh could not be found inside the app bundle."
            case .launchFailed(let message):
                "yh could not be launched: \(message)"
            }
        }
    }

    /// What to exec and the arguments that precede `yh`'s own: `/bin/sh <stub>` under the UI test
    /// override, otherwise the bundled `yh` alone.
    private struct LaunchPlan {
        let executable: URL
        let leadingArguments: [String]
    }

    private var process: Process?

    private static var launchPlan: LaunchPlan? {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let stubPath = arguments[stubArgument] as? String {
            return LaunchPlan(executable: URL(filePath: "/bin/sh"), leadingArguments: [stubPath])
        }
        guard let bundled = Bundle.main.url(forAuxiliaryExecutable: "yh") else { return nil }
        return LaunchPlan(executable: bundled, leadingArguments: [])
    }

    /// Terminates the current run, if any: closing the Setup window terminates the child process, since
    /// setup is not an Act. Safe to call when nothing is running.
    func terminate() {
        process?.terminate()
    }

    /// Runs `yh arguments`, writing `standardInput` (a trailing newline is the caller's job) and closing
    /// it before reading. Every merged output line, in order, reaches `onOutput` on the main actor.
    /// Returns the exit status.
    @discardableResult
    func run(
        arguments: [String], standardInput: String? = nil, onOutput: @escaping @MainActor (String) -> Void
    ) async throws -> Int32 {
        guard let plan = Self.launchPlan,
              FileManager.default.isExecutableFile(atPath: plan.executable.path(percentEncoded: false))
        else {
            throw RunError.executableNotFound
        }

        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.leadingArguments + arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        self.process = process

        // Set before `run()`: a `yh` that exits at once must still resume the wait below.
        let exited = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in continuation.finish() }
        }

        do {
            try process.run()
        } catch {
            self.process = nil
            throw RunError.launchFailed("\(error)")
        }

        if let standardInput, let data = standardInput.data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
        }
        try? inputPipe.fileHandleForWriting.close()

        // One ordered sequence, read to EOF: the wizard decodes `--print-choices` from the last line, so
        // no line may overtake another or arrive after the run is reported finished.
        do {
            for try await line in outputPipe.fileHandleForReading.bytes.lines {
                onOutput(line)
            }
        } catch {
            onOutput("yh output could not be read: \(error)")
        }
        for await _ in exited {}
        self.process = nil
        return process.terminationStatus
    }
}
