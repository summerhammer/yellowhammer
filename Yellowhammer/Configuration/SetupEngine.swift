import Darwin
import Foundation

/// Runs the bundled `yh` non-interactively and streams its merged stdout/stderr. The app never does the
/// Board work itself (ADR-001; the app links only Domain, Config and, read-only, Ledger) — this is the
/// seam the Setup wizard runs `SetupInvocation`'s argument vectors against, and the seam the Agent CLIs
/// window runs
/// `yh probe <cli>` through: the app never probes and never writes the Ledger itself, only `yh` does.
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

    /// Whether a UI test's stub stands in for the bundled `yh`.
    static var isStubbed: Bool {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[stubArgument] != nil
    }

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

        // A SwiftUI view can cancel the task awaiting this method as soon as navigation leaves it.
        // Keep the termination wait in an unstructured task so cancellation cannot make us read
        // terminationStatus before Foundation has observed the child's exit.
        let termination = Task.detached {
            for await _ in exited {}
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
        await termination.value
        self.process = nil
        return process.terminationStatus
    }

    /// Where a rehearsal Night's log lives (P14.7): `~/Library/Logs/Yellowhammer/<projectID>.rehearse.log`,
    /// matching the LaunchAgents' `<id>.<act>.log` naming — except under the UI-test stub override, where
    /// the log is written next to the stub file instead, so a UI test never writes into the real user's
    /// Logs.
    static func rehearsalLogURL(projectID: String) -> URL {
        let filename = "\(projectID).rehearse.log"
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let stubPath = arguments[stubArgument] as? String {
            return URL(filePath: stubPath).deletingLastPathComponent()
                .appending(component: filename, directoryHint: .notDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(components: "Library", "Logs", "Yellowhammer", filename, directoryHint: .notDirectory)
    }

    /// Launches `arguments` fully detached from the app (P14.7's rehearsal Night): the app must remain
    /// "shell, not host", so a Night launched from here must keep running with the app quit. `posix_spawn`s
    /// `/bin/sh` with `POSIX_SPAWN_SETSID`, running a script that backgrounds the real command and exits at
    /// once; only that shell is waited on, never the backgrounded grandchild, which is reparented to
    /// `launchd` — no pipe the app owns, so quitting never sends it a signal, and nothing here is held past
    /// this call ("nothing resident"). Throws on spawn failure or a non-zero shell exit.
    func launchDetached(arguments: [String], logURL: URL) throws {
        guard let plan = Self.launchPlan,
              FileManager.default.isExecutableFile(atPath: plan.executable.path(percentEncoded: false))
        else {
            throw RunError.executableNotFound
        }

        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch {
            throw RunError.launchFailed("could not create the log directory: \(error)")
        }

        let command = plan.executable.path(percentEncoded: false)
        let backgroundScript = #"log="$1"; shift; "$@" </dev/null >>"$log" 2>&1 &"#
        let shellArguments = ["/bin/sh", "-c", backgroundScript, "sh", logURL.path(percentEncoded: false), command]
            + plan.leadingArguments + arguments

        var argv: [UnsafeMutablePointer<CChar>?] = shellArguments.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, "/bin/sh", nil, &attributes, argv, environ)
        guard spawnResult == 0 else {
            throw RunError.launchFailed("posix_spawn failed with errno \(spawnResult)")
        }

        var status: Int32 = 0
        guard waitpid(pid, &status, 0) != -1 else {
            throw RunError.launchFailed("waiting for the detached shell failed: errno \(errno)")
        }
        let exited = (status & 0x7f) == 0
        let exitCode = (status >> 8) & 0xff
        guard exited, exitCode == 0 else {
            throw RunError.launchFailed("the detached shell did not exit cleanly (status \(status))")
        }
    }
}
