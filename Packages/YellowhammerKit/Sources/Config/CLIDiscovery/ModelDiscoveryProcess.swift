import Darwin
import Foundation

/// File-backed output avoids pipe backpressure; bounded `pread` avoids trusting a racy file-size check.
enum ModelDiscoveryProcess {
    private struct Streams {
        let input: [Int32]
        let stdout: Int32
        let stderr: Int32
    }
    static func run(
        vendor: ModelDiscoveryProtocol.Vendor, executable: String, environment: [String: String]
    ) async -> AgentModelDiscoveryResult {
        guard !Task.isCancelled else { return .failed("Model discovery was cancelled.") }
        guard let executable = resolve(executable, path: environment["PATH"] ?? "/usr/bin:/bin") else {
            return .failed("Could not find the installed CLI executable on PATH.")
        }
        if let refusal = refusal(vendor: vendor, executable: executable) { return .unsupported(refusal) }
        let directory: URL
        do {
            directory = try makeDirectory()
        } catch { return .failed("Could not prepare model discovery: \(error.localizedDescription)") }
        defer { try? FileManager.default.removeItem(at: directory) }

        let flags = O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC
        let stdout = open(directory.appendingPathComponent("stdout").path, flags, 0o600)
        let stderr = open(directory.appendingPathComponent("stderr").path, flags, 0o600)
        defer {
            closeIfOpen(stdout)
            closeIfOpen(stderr)
        }
        var input: [Int32] = [-1, -1]
        guard stdout >= 0, stderr >= 0, pipe(&input) == 0 else {
            return .failed("Could not open model-discovery files.")
        }
        defer {
            closeIfOpen(input[0])
            closeIfOpen(input[1])
        }
        // A CLI can close stdin early. Turn that into an error rather than SIGPIPE in the app.
        guard prepareInput(input) else {
            return .failed("Could not prepare model-discovery input.")
        }
        let pid: pid_t
        do {
            pid = try spawn(
                executable: executable, arguments: vendor.arguments, environment: environment,
                directory: directory.path, streams: Streams(input: input, stdout: stdout, stderr: stderr)
            )
        } catch { return .failed("Could not start model discovery: \(error.localizedDescription)") }
        close(input[0])
        input[0] = -1

        var protocolState = ModelDiscoveryProtocol(vendor: vendor)
        let result: AgentModelDiscoveryResult
        if send(protocolState.initialInput, to: input[1]) {
            result = await collect(
                pid: pid, stdout: stdout, stderr: stderr, input: input[1], protocolState: &protocolState
            )
        } else {
            result = .failed("The CLI closed its model-discovery input.")
        }
        // Shield cleanup from the caller's cancellation. A TERM-ignoring process cannot hang Settings.
        await Task.detached { await stop(pid) }.value
        return Task.isCancelled ? .failed("Model discovery was cancelled.") : result
    }

    private static func collect(
        pid: pid_t, stdout: Int32, stderr: Int32, input: Int32, protocolState: inout ModelDiscoveryProtocol
    ) async -> AgentModelDiscoveryResult {
        let deadline = ContinuousClock.now + AgentModelDiscovery.timeout
        var output = Data()
        var diagnostics = Data()
        var lineOffset = 0
        while true {
            if Task.isCancelled { return .failed("Model discovery was cancelled.") }
            if ContinuousClock.now >= deadline { return .failed("Model discovery timed out after 8 seconds.") }
            // Read the exit status first. If reaped, the final output is already available for this read.
            var status: Int32 = 0
            let waited = waitpid(pid, &status, WNOHANG)
            guard appendOutput(stdout, to: &output, otherBytes: diagnostics.count),
                  appendOutput(stderr, to: &diagnostics, otherBytes: output.count) else {
                return .failed("Model discovery output exceeded the combined 512 KiB limit.")
            }
            if let result = processLines(output, offset: &lineOffset, state: &protocolState, input: input) {
                return result
            }
            if waited == pid {
                return exited(status: status, output: output, diagnostics: diagnostics, vendor: protocolState.vendor)
            }
            if waited < 0, errno != EINTR { return .failed("Could not read the CLI's model-discovery exit status.") }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private static func processLines(
        _ output: Data, offset: inout Int, state: inout ModelDiscoveryProtocol, input: Int32
    ) -> AgentModelDiscoveryResult? {
        while let newline = output[offset...].firstIndex(of: 10) {
            guard let line = String(data: output[offset..<newline], encoding: .utf8) else {
                return .failed("The CLI returned invalid UTF-8 model-list output.")
            }
            offset = newline + 1
            switch state.receive(line) {
            case .waiting: break
            case .send(let request):
                if !send(request, to: input) { return .failed("The CLI closed its model-discovery input.") }
            case .complete(let models): return .live(models: unique(models))
            case .failed(let message): return .failed(message)
            }
        }
        return nil
    }

    private static func exited(
        status: Int32, output: Data, diagnostics: Data, vendor: ModelDiscoveryProtocol.Vendor
    ) -> AgentModelDiscoveryResult {
        guard status == 0 else {
            let detail = String(data: diagnostics, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let fallback = "The CLI exited before returning a model list (status \(status))."
            return .failed(detail.isEmpty ? fallback : String(detail.prefix(1_000)))
        }
        guard vendor == .agy, let text = String(data: output, encoding: .utf8),
              let models = AgentModelDiscovery.parseAntigravityModels(text) else {
            return .failed("The CLI did not return a valid model-list response.")
        }
        return .live(models: unique(models))
    }

    private static func appendOutput(_ descriptor: Int32, to output: inout Data, otherBytes: Int) -> Bool {
        let remaining = AgentModelDiscovery.maximumOutputBytes - output.count - otherBytes
        guard remaining >= 0 else { return false }
        var bytes = [UInt8](repeating: 0, count: min(remaining + 1, 64 * 1024))
        while true {
            let count = pread(descriptor, &bytes, bytes.count, off_t(output.count))
            if count < 0 { if errno == EINTR { continue }; return false }
            if count == 0 { return true }
            guard count <= AgentModelDiscovery.maximumOutputBytes - output.count - otherBytes else { return false }
            output.append(contentsOf: bytes.prefix(count))
        }
    }

    private static func send(_ request: String, to descriptor: Int32) -> Bool {
        guard !request.isEmpty else { return true }
        let data = Data(request.utf8)
        return data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    private static func stop(_ pid: pid_t) async {
        kill(-pid, SIGTERM)
        let grace = ContinuousClock.now + .milliseconds(150)
        var status: Int32 = 0
        while ContinuousClock.now < grace {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid || (waited < 0 && errno == ECHILD) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        // Always kill the group, including descendants left behind by an already exited CLI.
        kill(-pid, SIGKILL)
        let deadline = ContinuousClock.now + .milliseconds(850)
        while ContinuousClock.now < deadline {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid || (waited < 0 && errno == ECHILD) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func spawn(
        executable: String, arguments: [String], environment: [String: String], directory: String,
        streams: Streams
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try checked(posix_spawn_file_actions_addchdir(&actions, directory))
        try checked(posix_spawn_file_actions_adddup2(&actions, streams.input[0], STDIN_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, streams.stdout, STDOUT_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, streams.stderr, STDERR_FILENO))
        try checked(posix_spawn_file_actions_addclose(&actions, streams.input[0]))
        try checked(posix_spawn_file_actions_addclose(&actions, streams.input[1]))
        try checked(posix_spawn_file_actions_addclose(&actions, streams.stdout))
        try checked(posix_spawn_file_actions_addclose(&actions, streams.stderr))
        // SETPGROUP is atomic with spawn. Calling setpgid after exec races and returns EACCES on macOS.
        try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try checked(posix_spawnattr_setpgroup(&attributes, 0))
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        try checked(posix_spawn(&pid, executable, &actions, &attributes, argv, envp))
        return pid
    }

    private static func prepareInput(_ input: [Int32]) -> Bool {
        fcntl(input[1], F_SETNOSIGPIPE, 1) == 0
            && fcntl(input[1], F_SETFL, O_NONBLOCK) == 0
            && fcntl(input[0], F_SETFD, FD_CLOEXEC) == 0
            && fcntl(input[1], F_SETFD, FD_CLOEXEC) == 0
    }

    private static func closeIfOpen(_ descriptor: Int32) {
        if descriptor >= 0 { close(descriptor) }
    }

    private static func checked(_ code: Int32) throws {
        if code != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
    }

    private static func resolve(_ executable: String, path: String) -> String? {
        if executable.hasPrefix("/") {
            return ExecutableFile.isRunnable(atPath: executable) ? executable : nil
        }
        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(executable).path
            if ExecutableFile.isRunnable(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func refusal(vendor: ModelDiscoveryProtocol.Vendor, executable: String) -> String? {
        guard let descriptor = AgentCLIDescriptors.all.first(where: { $0.cli == vendor.rawValue }),
              let resolvedPath = ExecutableFile.resolvedPath(executable) else { return nil }
        return descriptor.refusal(executable, resolvedPath)
    }

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yh-model-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private static func unique(_ models: [AgentModel]) -> [AgentModel] {
        var seen: Set<String> = []
        return models.filter { seen.insert($0.id).inserted }
    }
}
