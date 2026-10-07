import Darwin
import Foundation

/// Reads the `PATH` the Operator's login shell ends up with, which a Finder-launched app does not inherit.
/// The shell is run once, bounded by a timeout, with its output going to a file.
public enum LoginShellPATH {
    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        case spawnFailed(String)
        case timedOut(Duration)
        case noPATHPrinted
        /// The task reading it was cancelled, e.g. because the pane closed.
        case cancelled

        public var description: String {
            switch self {
            case .spawnFailed(let reason):
                return "Your login shell\u{2019}s PATH could not be read: the shell did not start (\(reason))."
            case .timedOut(let limit):
                return "Your login shell\u{2019}s PATH could not be read: it did not finish within "
                    + "\(Self.words(limit))."
            case .noPATHPrinted:
                return "Your login shell\u{2019}s PATH could not be read: the shell printed no PATH."
            case .cancelled:
                return "Your login shell\u{2019}s PATH was not read: the search was cancelled."
            }
        }

        private static func words(_ duration: Duration) -> String {
            let seconds = Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
            return "\(seconds.formatted(.number.precision(.fractionLength(0...1)))) seconds"
        }
    }

    public enum Result: Equatable, Sendable {
        case path(String)
        case failed(Failure)
    }

    /// The Operator's login shell from the password database when it is an absolute executable path;
    /// otherwise `/bin/zsh`.
    public static func operatorShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    /// The shell command that prints `PATH` between two `marker`s, so rc-file noise around it can be ignored.
    /// fish keeps `PATH` as a list that `"$PATH"` joins with spaces, so for fish it is joined with `:` instead.
    public static func command(marker: String, shell: String = "/bin/zsh") -> String {
        let path = (shell as NSString).lastPathComponent == "fish" ? "string join ':' $PATH" : "printf '%s' \"$PATH\""
        return "printf '%s' '\(marker)'; \(path); printf '%s' '\(marker)'"
    }

    /// The `PATH` between the first `marker` in `output` and the next one, after ANSI escape sequences are
    /// removed; nil when either marker is missing or the `PATH` is blank.
    public static func parse(output: String, marker: String) -> String? {
        let operatingSystemCommands = "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)"
        let controlSequences = "\u{1B}\\[[0-9;?]*[ -/]*[@-~]"
        let clean = output
            .replacingOccurrences(of: operatingSystemCommands, with: "", options: .regularExpression)
            .replacingOccurrences(of: controlSequences, with: "", options: .regularExpression)
        guard let start = clean.range(of: marker),
              let end = clean.range(of: marker, range: start.upperBound..<clean.endIndex) else { return nil }
        let value = clean[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// The arguments that run `command` in `shell` as a login shell (and interactive, so the rc files that
    /// set `PATH` run), adjusted for shells that spell that differently.
    public static func arguments(shell: String, command: String) -> [String] {
        switch (shell as NSString).lastPathComponent {
        case "fish": return ["-l", "-c", command]
        case "csh", "tcsh": return ["-c", command]
        default: return ["-l", "-i", "-c", command]
        }
    }

    /// Runs `shell` and reads its `PATH`. The shell gets no stdin and its own process group, which is killed
    /// when `timeout` passes.
    public static func read(
        shell: String = operatorShell(),
        timeout: Duration = .seconds(10),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> Result {
        let marker = "YH-\(UUID().uuidString)"
        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("yh-login-path-\(UUID().uuidString)").path
        defer { unlink(outputPath) }
        var env = environment
        env["YELLOWHAMMER_RESOLVING_ENVIRONMENT"] = "1"
        env["DISABLE_AUTO_UPDATE"] = "true"

        let pid: pid_t
        switch spawn(
            shell: shell, arguments: arguments(shell: shell, command: command(marker: marker, shell: shell)),
            environment: env, outputPath: outputPath
        ) {
        case .success(let spawned): pid = spawned
        case .failure(let failure): return .failed(failure)
        }

        let deadline = ContinuousClock.now + timeout
        var status: Int32 = 0
        while waitpid(pid, &status, WNOHANG) == 0 {
            // A cancelled task makes `Task.sleep` return at once, so it ends the wait too, rather than spinning
            // until the deadline.
            if Task.isCancelled || ContinuousClock.now >= deadline {
                kill(-pid, SIGKILL)
                waitpid(pid, &status, 0)
                return .failed(Task.isCancelled ? .cancelled : .timedOut(timeout))
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        let output = (try? String(contentsOfFile: outputPath, encoding: .utf8)) ?? ""
        guard let path = parse(output: output, marker: marker) else { return .failed(.noPATHPrinted) }
        return .path(path)
    }

    private static func spawn(
        shell: String, arguments: [String], environment: [String: String], outputPath: String
    ) -> Swift.Result<pid_t, Failure> {
        let fd = open(outputPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return .failure(.spawnFailed(String(cString: strerror(errno)))) }
        defer { close(fd) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fd, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fd, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = ([shell] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, shell, &actions, &attributes, argv, envp)
        guard code == 0 else { return .failure(.spawnFailed(String(cString: strerror(code)))) }
        return .success(pid)
    }
}
