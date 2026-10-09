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
        logURL(projectID: projectID, command: "rehearse")
    }

    /// The same log as the selected Project's LaunchAgent; the stub seam keeps output beside the stub.
    static func logURL(projectID: String, command: String) -> URL {
        let filename = "\(projectID).\(command).log"
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let stubPath = arguments[stubArgument] as? String {
            return URL(filePath: stubPath).deletingLastPathComponent()
                .appending(component: filename, directoryHint: .notDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(components: "Library", "Logs", "Yellowhammer", filename, directoryHint: .notDirectory)
    }

    /// Launches `arguments` fully detached from the app (an Act or P14.7's rehearsal Night): the app must remain
    /// "shell, not host", so a Night launched from here must keep running with the app quit. `posix_spawn`s
    /// `/bin/sh` with `POSIX_SPAWN_SETSID`, running a script that backgrounds the real command and exits at
    /// once; only that shell is waited on, never the backgrounded child, which is reparented to `launchd`.
    /// With `onCompletion`, an EOF-only pipe reports when the command exits; app exit closes the reader and
    /// never signals the child. Throws on spawn failure or a non-zero shell exit.
    func launchDetached(
        arguments: [String], logURL: URL, onCompletion: (@MainActor @Sendable () -> Void)? = nil
    ) throws {
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

        let shellArguments = Self.detachedShellArguments(plan: plan, arguments: arguments, logURL: logURL,
                                                        awaitsCompletion: onCompletion != nil)
        var completionPipe = onCompletion == nil ? nil : try Self.makeCompletionPipe()
        defer { completionPipe?.forEach { if $0 >= 0 { close($0) } } }

        let pid = try Self.spawnDetachedShell(arguments: shellArguments, completionPipe: completionPipe)
        if let onCompletion, let descriptors = completionPipe {
            close(descriptors[1])
            completionPipe?[1] = -1
            let readDescriptor = descriptors[0]
            completionPipe?[0] = -1
            Self.notifyOnEOF(readDescriptor, onCompletion: onCompletion)
        }
        try Self.waitForDetachedShell(pid)
    }

    private nonisolated static func detachedShellArguments(
        plan: LaunchPlan, arguments: [String], logURL: URL, awaitsCompletion: Bool
    ) -> [String] {
        // Ignore HUP before backgrounding the descriptor-holding wrapper; the shell's exit otherwise kills it.
        let backgroundCommand = awaitsCompletion
            ? #"trap '' HUP; (trap '' HUP; "$@" </dev/null 3>&- & child=$!; wait "$child"; exec 3>&-) &"#
            : #""$@" </dev/null &"#
        let script = #"log="$1"; shift; exec >>"$log" 2>&1 || exit 1; \#(backgroundCommand)"#
        return ["/bin/sh", "-c", script, "sh", logURL.path(percentEncoded: false),
                plan.executable.path(percentEncoded: false)] + plan.leadingArguments + arguments
    }

    private nonisolated static func makeCompletionPipe() throws -> [Int32] {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else {
            throw RunError.launchFailed("could not create the completion pipe: errno \(errno)")
        }
        let readDescriptor = fcntl(descriptors[0], F_DUPFD_CLOEXEC, 4)
        let writeDescriptor = fcntl(descriptors[1], F_DUPFD_CLOEXEC, 4)
        close(descriptors[0])
        close(descriptors[1])
        guard readDescriptor >= 0, writeDescriptor >= 0 else {
            if readDescriptor >= 0 { close(readDescriptor) }
            if writeDescriptor >= 0 { close(writeDescriptor) }
            throw RunError.launchFailed("could not prepare the completion pipe: errno \(errno)")
        }
        return [readDescriptor, writeDescriptor]
    }

    private nonisolated static func spawnDetachedShell(
        arguments: [String], completionPipe: [Int32]?
    ) throws -> pid_t {
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw RunError.launchFailed("could not initialize spawn attributes")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID)) == 0 else {
            throw RunError.launchFailed("could not configure detached session")
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw RunError.launchFailed("could not initialize spawn file actions")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        if let completionPipe {
            // The wrapper holds descriptor 3 open; the command itself closes it before exec.
            guard posix_spawn_file_actions_adddup2(&fileActions, completionPipe[1], 3) == 0,
                  posix_spawn_file_actions_addclose(&fileActions, completionPipe[0]) == 0,
                  posix_spawn_file_actions_addclose(&fileActions, completionPipe[1]) == 0
            else {
                throw RunError.launchFailed("could not configure the completion pipe")
            }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/sh", &fileActions, &attributes, argv, environ)
        guard result == 0 else { throw RunError.launchFailed("posix_spawn failed with errno \(result)") }
        return pid
    }

    private nonisolated static func notifyOnEOF(
        _ descriptor: Int32, onCompletion: @escaping @MainActor @Sendable () -> Void
    ) {
        DispatchQueue.global().async {
            var byte: UInt8 = 0
            while true {
                let result = read(descriptor, &byte, 1)
                if result > 0 { continue }
                if result == -1 && errno == EINTR { continue }
                break
            }
            close(descriptor)
            Task { @MainActor in onCompletion() }
        }
    }

    private nonisolated static func waitForDetachedShell(_ pid: pid_t) throws {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 {
            if errno == EINTR { continue }
            throw RunError.launchFailed("waiting for the detached shell failed: errno \(errno)")
        }
        let exited = (status & 0x7f) == 0
        let exitCode = (status >> 8) & 0xff
        guard exited, exitCode == 0 else {
            throw RunError.launchFailed("the detached shell did not exit cleanly (status \(status))")
        }
    }
}
