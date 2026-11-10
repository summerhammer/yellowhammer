import CLIAdapters
import Darwin
import Domain
import Foundation
import Testing

private final class BundleAnchor {}

private func productsDirectory() -> URL {
    let bundle = Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" } ?? Bundle(for: BundleAnchor.self)
    return bundle.bundleURL.deletingLastPathComponent()
}

private struct SpawnResult {
    let pid: pid_t
    let status: Int32
    let stdout: String
}

@Suite("PassWrapper and PassLauncher tests")
struct PassWrapperTests {
    private func passWrapperChildURL() throws -> URL {
        let executable = productsDirectory().appending(component: "PassWrapperChild")
        try #require(
            FileManager.default.isExecutableFile(atPath: executable.path),
            "PassWrapperChild is not built at \(executable.path); run `swift build --build-tests`"
        )
        return executable
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExecutableScript(at url: URL, content: String) throws {
        let script = "#!/bin/sh\n" + content + "\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func spawnInFreshSession(
        executable: String,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> SpawnResult {
        var stdoutPipe: [Int32] = [-1, -1]
        guard pipe(&stdoutPipe) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            if stdoutPipe[0] >= 0 { close(stdoutPipe[0]) }
            if stdoutPipe[1] >= 0 { close(stdoutPipe[1]) }
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], 1)
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0])

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attr, Int16(flags))

        let argv = [strdup(executable)] + arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for ptr in argv where ptr != nil { free(ptr) }
            for ptr in envp where ptr != nil { free(ptr) }
        }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &fileActions, &attr, argv, envp)
        close(stdoutPipe[1])
        stdoutPipe[1] = -1

        guard rc == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO)
        }

        var outputData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(stdoutPipe[0], &buffer, buffer.count)
            if bytesRead > 0 {
                outputData.append(buffer, count: bytesRead)
            } else if bytesRead < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }

        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}

        let stdoutString = String(bytes: outputData, encoding: .utf8) ?? ""
        return SpawnResult(pid: pid, status: status, stdout: stdoutString)
    }

    private func runScenario(stubContent: String) throws -> (PassWrapperStatus, URL) {
        let wrapperBin = try passWrapperChildURL()
        let dir = try makeTemporaryDirectory()

        let worktree = dir.appendingPathComponent("worktree")
        let runDir = dir.appendingPathComponent("rundir")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)

        let stub = dir.appendingPathComponent("stub.sh")
        try makeExecutableScript(at: stub, content: stubContent)

        let statusPath = runDir.appendingPathComponent("status.json").path
        let spec = PassWrapperSpec(
            executable: stub.path,
            argv: [],
            worktreePath: worktree.path,
            stdoutCapturePath: runDir.appendingPathComponent("stdout.log").path,
            startedPath: runDir.appendingPathComponent("started.json").path,
            statusPath: statusPath
        )
        let specURL = runDir.appendingPathComponent("spec.json")
        try spec.write(to: specURL)

        _ = try spawnInFreshSession(executable: wrapperBin.path, arguments: [specURL.path])
        let statusData = try Data(contentsOf: URL(fileURLWithPath: statusPath))
        let record = try JSONDecoder().decode(PassWrapperStatus.self, from: statusData)
        return (record, dir)
    }

    // MARK: - Test Cases

    @Test("CLI is spawned with pid == pgid == sid in the Worktree with stdin /dev/null")
    func cliIdentityAndWorktree() throws {
        let wrapperBin = try passWrapperChildURL()
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let worktree = dir.appendingPathComponent("worktree")
        let runDir = dir.appendingPathComponent("rundir")
        let scratch = dir.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let stubCLI = dir.appendingPathComponent("stub.sh")
        try makeExecutableScript(
            at: stubCLI,
            content: """
            pwd > "\(scratch.path)/cwd"
            ps -o pgid= -p $$ | tr -d ' ' > "\(scratch.path)/pgid"
            echo $$ > "\(scratch.path)/pid"
            if read -r line; then echo open > "\(scratch.path)/stdin"; else echo closed > "\(scratch.path)/stdin"; fi
            exit 0
            """
        )

        let startedPath = runDir.appendingPathComponent(PassWrapper.startedFileName).path
        let statusPath = runDir.appendingPathComponent(PassWrapper.statusFileName).path
        let spec = PassWrapperSpec(
            executable: stubCLI.path,
            argv: [scratch.path],
            worktreePath: worktree.path,
            stdoutCapturePath: runDir.appendingPathComponent("capture.log").path,
            startedPath: startedPath,
            statusPath: statusPath
        )
        let specURL = runDir.appendingPathComponent(PassWrapper.specFileName)
        try spec.write(to: specURL)

        let launcherURL = runDir.appendingPathComponent(PassLauncher.fileName)
        try PassLauncher.writeLauncher(
            to: launcherURL,
            wrapperExecutable: wrapperBin.path,
            specPath: specURL.path,
            addedEnvironment: ["EXTRA_TEST_VAR": "hello"]
        )

        let result = try spawnInFreshSession(executable: "/bin/bash", arguments: [launcherURL.path])
        #expect(result.status == 0)

        try verifyReportedCLIIdentity(
            scratch: scratch,
            worktree: worktree,
            startedPath: startedPath,
            statusPath: statusPath
        )
    }

    private func verifyReportedCLIIdentity(
        scratch: URL,
        worktree: URL,
        startedPath: String,
        statusPath: String
    ) throws {
        let reportedCwd = try String(contentsOf: scratch.appendingPathComponent("cwd"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reportedPgid = try String(contentsOf: scratch.appendingPathComponent("pgid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reportedPid = try String(contentsOf: scratch.appendingPathComponent("pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reportedStdin = try String(contentsOf: scratch.appendingPathComponent("stdin"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(
            URL(fileURLWithPath: reportedCwd).resolvingSymlinksInPath().path ==
            worktree.resolvingSymlinksInPath().path
        )
        #expect(reportedPgid == reportedPid)
        #expect(reportedStdin == "closed")

        let startedData = try Data(contentsOf: URL(fileURLWithPath: startedPath))
        let started = try JSONDecoder().decode(PassWrapperStarted.self, from: startedData)
        #expect(String(started.pid) == reportedPid)
        #expect(String(started.processGroup) == reportedPid)
        #expect(String(started.session) == reportedPid)
        #expect(started.startSeconds > 0)

        let statusData = try Data(contentsOf: URL(fileURLWithPath: statusPath))
        let status = try JSONDecoder().decode(PassWrapperStatus.self, from: statusData)
        #expect(status.exitStatus == 0)
        #expect(status.signal == nil)
        #expect(status.receivedSignals == [])
    }

    @Test("Status record records exit 0")
    func exitZeroStatus() throws {
        let (record, dir) = try runScenario(stubContent: "exit 0")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(record.exitStatus == 0)
        #expect(record.signal == nil)
        #expect(record.receivedSignals == [])
    }

    @Test("Status record records non-zero exit")
    func nonZeroExitStatus() throws {
        let (record, dir) = try runScenario(stubContent: "exit 3")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(record.exitStatus == 3)
        #expect(record.signal == nil)
        #expect(record.receivedSignals == [])
    }

    @Test("Status record records foreign SIGKILL")
    func sigkillStatus() throws {
        let (record, dir) = try runScenario(stubContent: "kill -KILL $$")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(record.exitStatus == nil)
        #expect(record.signal == 9)
        #expect(record.receivedSignals == [])
    }

    @Test("Stdout lands in capture file and wrapper stdout, and failed stdout write never loses capture")
    func stdoutTeeing() throws {
        let wrapperBin = try passWrapperChildURL()
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let worktree = dir.appendingPathComponent("worktree")
        let runDir = dir.appendingPathComponent("rundir")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)

        let stub = dir.appendingPathComponent("stub.sh")
        try makeExecutableScript(
            at: stub,
            content: """
            echo "alpha output"
            echo "beta output"
            exit 0
            """
        )

        let capturePath = runDir.appendingPathComponent("stdout.log").path
        let spec = PassWrapperSpec(
            executable: stub.path,
            argv: [],
            worktreePath: worktree.path,
            stdoutCapturePath: capturePath,
            startedPath: runDir.appendingPathComponent("started.json").path,
            statusPath: runDir.appendingPathComponent("status.json").path
        )
        let specURL = runDir.appendingPathComponent("spec.json")
        try spec.write(to: specURL)

        let result = try spawnInFreshSession(executable: wrapperBin.path, arguments: [specURL.path])
        #expect(result.stdout.contains("alpha output"))
        #expect(result.stdout.contains("beta output"))

        let captured = try String(contentsOf: URL(fileURLWithPath: capturePath), encoding: .utf8)
        #expect(captured.contains("alpha output"))
        #expect(captured.contains("beta output"))
    }

    @Test("SIGTERM sent to wrapper is recorded and ends the CLI")
    func signalForwardingAndRecording() throws {
        let wrapperBin = try passWrapperChildURL()
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let worktree = dir.appendingPathComponent("worktree")
        let runDir = dir.appendingPathComponent("rundir")
        let scratch = dir.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let stub = dir.appendingPathComponent("stub.sh")
        try makeExecutableScript(
            at: stub,
            content: """
            echo $$ > "\(scratch.path)/child_pid"
            exec sleep 60
            """
        )

        let startedPath = runDir.appendingPathComponent("started.json").path
        let statusPath = runDir.appendingPathComponent("status.json").path
        let spec = PassWrapperSpec(
            executable: stub.path,
            argv: [],
            worktreePath: worktree.path,
            stdoutCapturePath: runDir.appendingPathComponent("stdout.log").path,
            startedPath: startedPath,
            statusPath: statusPath
        )
        let specURL = runDir.appendingPathComponent("spec.json")
        try spec.write(to: specURL)

        let wrapperPid = try spawnWrapperProcess(wrapperBin: wrapperBin, specURL: specURL)
        let started = try waitForStartedRecord(startedPath: startedPath)

        kill(wrapperPid, SIGTERM)

        var status: Int32 = 0
        while waitpid(wrapperPid, &status, 0) < 0 && errno == EINTR {}

        let statusData = try Data(contentsOf: URL(fileURLWithPath: statusPath))
        let statusRecord = try JSONDecoder().decode(PassWrapperStatus.self, from: statusData)

        #expect(statusRecord.receivedSignals == [SIGTERM])
        #expect(statusRecord.exitStatus == 143 || statusRecord.signal == SIGTERM)
        #expect(kill(started.pid, 0) != 0)
    }

    private func spawnWrapperProcess(wrapperBin: URL, specURL: URL) throws -> pid_t {
        let argv = [strdup(wrapperBin.path), strdup(specURL.path), nil]
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for ptr in argv where ptr != nil { free(ptr) }
            for ptr in envp where ptr != nil { free(ptr) }
        }
        var wrapperPid: pid_t = 0
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attr, Int16(flags))

        let rc = posix_spawn(&wrapperPid, wrapperBin.path, &fileActions, &attr, argv, envp)
        guard rc == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO)
        }
        return wrapperPid
    }

    private func waitForStartedRecord(startedPath: String) throws -> PassWrapperStarted {
        var startedData: Data?
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: startedPath)), !data.isEmpty {
                startedData = data
                break
            }
            usleep(20000)
        }
        let data = try #require(startedData)
        return try JSONDecoder().decode(PassWrapperStarted.self, from: data)
    }

    @Test("Launcher exports only added variables and preserves tab environment")
    func launcherExportsOnlyAddedVariables() throws {
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let specURL = dir.appendingPathComponent("spec.json")
        let launcherURL = dir.appendingPathComponent("launcher.sh")

        let script = PassLauncher.script(
            wrapperExecutable: "/usr/local/bin/yh",
            specPath: specURL.path,
            addedEnvironment: [
                "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1",
                "MY_CUSTOM_VAR": "val with 'single quote' and spaces"
            ]
        )

        #expect(script.contains("export CLAUDE_CODE_DISABLE_BACKGROUND_TASKS='1'"))
        #expect(script.contains("export MY_CUSTOM_VAR='val with '\\''single quote'\\'' and spaces'"))
        #expect(!script.contains("PATH"))
        #expect(!script.contains("USER"))
        #expect(!script.contains("exec "))

        try PassLauncher.writeLauncher(
            to: launcherURL,
            wrapperExecutable: "/bin/echo",
            specPath: specURL.path,
            addedEnvironment: ["TEST_ADDED_ENV": "active"]
        )

        let attrs = try FileManager.default.attributesOfItem(atPath: launcherURL.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o700)
    }

    @Test("Launcher shell stays running after wrapper ends (never execs)")
    func launcherShellNeverExecs() throws {
        let wrapperBin = try passWrapperChildURL()
        let dir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let worktree = dir.appendingPathComponent("worktree")
        let runDir = dir.appendingPathComponent("rundir")
        let scratch = dir.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let stub = dir.appendingPathComponent("stub.sh")
        try makeExecutableScript(at: stub, content: "exit 0")

        let spec = PassWrapperSpec(
            executable: stub.path,
            argv: [],
            worktreePath: worktree.path,
            stdoutCapturePath: runDir.appendingPathComponent("stdout.log").path,
            startedPath: runDir.appendingPathComponent("started.json").path,
            statusPath: runDir.appendingPathComponent("status.json").path
        )
        let specURL = runDir.appendingPathComponent("spec.json")
        try spec.write(to: specURL)

        let launcherURL = runDir.appendingPathComponent("launcher.sh")
        try PassLauncher.writeLauncher(
            to: launcherURL,
            wrapperExecutable: wrapperBin.path,
            specPath: specURL.path,
            addedEnvironment: [:]
        )

        let marker = scratch.appendingPathComponent("marker.txt")
        let bashCommand = "\(launcherURL.path); echo shell_still_active > \"\(marker.path)\""

        let result = try spawnInFreshSession(executable: "/bin/bash", arguments: ["-c", bashCommand])
        #expect(result.status == 0)

        let markerText = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(markerText == "shell_still_active")
    }

    @Test("AgentCLILaunch addedEnvironment carries adapter-specific additions")
    func adapterAddedEnvironment() throws {
        let fixture = try CLIDispatchFixture.make()
        defer { fixture.cleanUp() }

        let claudeDispatch = fixture.dispatch(cli: "claude", environment: ["ORIGINAL": "1"])
        let adapter = ClaudeCodeAdapter()
        let launch = try adapter.launch(for: claudeDispatch)
        #expect(launch.addedEnvironment == ["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1"])
        #expect(launch.environment["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"] == "1")
        #expect(launch.environment["ORIGINAL"] == "1")

        let codexDispatch = fixture.dispatch(cli: "codex", environment: ["ORIGINAL": "1"])
        let codex = CodexAdapter()
        let codexLaunch = try codex.launch(for: codexDispatch)
        #expect(codexLaunch.addedEnvironment.isEmpty)

        let agyDispatch = fixture.dispatch(cli: "agy", environment: ["ORIGINAL": "1"])
        let antigravity = AntigravityAdapter()
        let antigravityLaunch = try antigravity.launch(for: agyDispatch)
        #expect(antigravityLaunch.addedEnvironment.isEmpty)
    }
}
