import Darwin
import Foundation

// MARK: - Global signal forwarding state

private nonisolated(unsafe) var passWrapperSignalPipeWriteFD: Int32 = -1
private nonisolated(unsafe) var passWrapperChildProcessGroup: pid_t = 0

private let passWrapperSignalHandler: @convention(c) (Int32) -> Void = { sig in
    if passWrapperChildProcessGroup > 0 {
        kill(-passWrapperChildProcessGroup, sig)
    }
    if passWrapperSignalPipeWriteFD >= 0 {
        var signalNumber = UInt8(sig)
        write(passWrapperSignalPipeWriteFD, &signalNumber, 1)
    }
}

// MARK: - PassWrapper

/// Runs an agent CLI pass as its own session leader in an Orca terminal tab (ADR-007 items 6 & 9).
public enum PassWrapper {
    public static let startedFileName = "wrapper-started.json"
    public static let statusFileName = "wrapper-status.json"
    public static let specFileName = "wrapper-spec.json"
    public static let launcherFileName = "launcher.sh"

    private struct SignalChannel {
        let readFD: Int32
        let writeFD: Int32
    }

    private struct TeeSession {
        let thread: Thread
        let captureFD: Int32
    }

    private struct StartIdentity {
        let startSeconds: UInt64
        let startMicroseconds: UInt64
        let session: pid_t
        let processGroup: pid_t
    }

    /// Loads the spec file from `specPath` and runs the pass wrapper.
    @discardableResult
    public static func run(specPath: String) throws -> PassWrapperStatus {
        let specURL = URL(fileURLWithPath: specPath)
        let data = try Data(contentsOf: specURL)
        let spec = try JSONDecoder().decode(PassWrapperSpec.self, from: data)
        return try run(spec: spec)
    }

    /// Executes the pass specified by `spec`.
    @discardableResult
    public static func run(spec: PassWrapperSpec) throws -> PassWrapperStatus {
        signal(SIGPIPE, SIG_IGN)

        let channel = try openSignalPipe()
        defer {
            if channel.readFD >= 0 { close(channel.readFD) }
            if channel.writeFD >= 0 { close(channel.writeFD) }
        }
        passWrapperSignalPipeWriteFD = channel.writeFD
        passWrapperChildProcessGroup = 0

        var oldTerm = sigaction()
        var oldHup = sigaction()
        var oldInt = sigaction()
        var oldSigMask = sigset_t()
        installSignalHandlers(oldTerm: &oldTerm, oldHup: &oldHup, oldInt: &oldInt, oldSigMask: &oldSigMask)
        defer {
            restoreSignalHandlers(oldTerm: &oldTerm, oldHup: &oldHup, oldInt: &oldInt, oldSigMask: &oldSigMask)
        }

        var stdoutPipe: [Int32] = [-1, -1]
        guard pipe(&stdoutPipe) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            if stdoutPipe[0] >= 0 { close(stdoutPipe[0]) }
        }

        let childPid = try spawnChild(spec: spec, stdoutPipe: &stdoutPipe)
        passWrapperChildProcessGroup = childPid

        try writeStartedRecord(spec: spec, childPid: childPid)

        let tee = startStdoutTee(readPipeFD: stdoutPipe[0], capturePath: spec.stdoutCapturePath)
        defer {
            if tee.captureFD >= 0 { close(tee.captureFD) }
        }

        let status = waitForChildExit(childPid: childPid)
        passWrapperChildProcessGroup = 0

        close(stdoutPipe[0])
        stdoutPipe[0] = -1
        while tee.thread.isExecuting {
            Thread.sleep(forTimeInterval: 0.005)
        }

        let receivedSignals = drainReceivedSignals(readFD: channel.readFD)
        return try writeStatusRecord(spec: spec, status: status, receivedSignals: receivedSignals)
    }

    /// Atomically writes data to `destinationURL` via a temp file in the same directory and `rename`.
    public static func writeAtomic(data: Data, to destinationURL: URL) throws {
        let parentDir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let tempURL = parentDir.appendingPathComponent(".\(destinationURL.lastPathComponent).tmp.\(UUID().uuidString)")
        try data.write(to: tempURL)
        let result = rename(tempURL.path, destinationURL.path)
        if result != 0 {
            let err = errno
            try? FileManager.default.removeItem(at: tempURL)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
    }
}

// MARK: - Internal Plumbing

extension PassWrapper {
    // MARK: - Signal plumbing

    private static func openSignalPipe() throws -> SignalChannel {
        var signalPipe: [Int32] = [-1, -1]
        guard pipe(&signalPipe) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        _ = fcntl(signalPipe[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(signalPipe[1], F_SETFL, O_NONBLOCK)
        return SignalChannel(readFD: signalPipe[0], writeFD: signalPipe[1])
    }

    private static func installSignalHandlers(
        oldTerm: inout sigaction,
        oldHup: inout sigaction,
        oldInt: inout sigaction,
        oldSigMask: inout sigset_t
    ) {
        var sa = sigaction()
        sa.__sigaction_u.__sa_handler = passWrapperSignalHandler
        sigemptyset(&sa.sa_mask)
        sa.sa_flags = 0

        sigaction(SIGTERM, &sa, &oldTerm)
        sigaction(SIGHUP, &sa, &oldHup)
        sigaction(SIGINT, &sa, &oldInt)

        var emptySigMask = sigset_t()
        sigemptyset(&emptySigMask)
        pthread_sigmask(SIG_SETMASK, &emptySigMask, &oldSigMask)
    }

    private static func restoreSignalHandlers(
        oldTerm: inout sigaction,
        oldHup: inout sigaction,
        oldInt: inout sigaction,
        oldSigMask: inout sigset_t
    ) {
        pthread_sigmask(SIG_SETMASK, &oldSigMask, nil)
        sigaction(SIGTERM, &oldTerm, nil)
        sigaction(SIGHUP, &oldHup, nil)
        sigaction(SIGINT, &oldInt, nil)
        passWrapperSignalPipeWriteFD = -1
        passWrapperChildProcessGroup = 0
    }

    private static func drainReceivedSignals(readFD: Int32) -> [Int32] {
        var receivedSignals: [Int32] = []
        var sigByte: UInt8 = 0
        while true {
            let count = read(readFD, &sigByte, 1)
            if count == 1 {
                receivedSignals.append(Int32(sigByte))
            } else {
                break
            }
        }
        return receivedSignals
    }

    // MARK: - Spawning

    private static func spawnChild(spec: PassWrapperSpec, stdoutPipe: inout [Int32]) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        posix_spawn_file_actions_addchdir(&fileActions, spec.worktreePath)
        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], 1)
        posix_spawn_file_actions_addclose(&fileActions, stdoutPipe[0])

        let stderrPath = spec.stderrPath ?? "/dev/null"
        posix_spawn_file_actions_addopen(&fileActions, 2, stderrPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attr, Int16(flags))

        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)

        let rawArgv: [String] = (spec.argv.first == spec.executable) ? spec.argv : ([spec.executable] + spec.argv)
        let argv = cStringArray(rawArgv)
        let envStrings = ProcessInfo.processInfo.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let envp = cStringArray(envStrings)
        defer {
            freeCStringArray(argv)
            freeCStringArray(envp)
        }

        var childPid: pid_t = 0
        let rc = posix_spawn(&childPid, spec.executable, &fileActions, &attr, argv, envp)
        close(stdoutPipe[1])
        stdoutPipe[1] = -1

        guard rc == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO)
        }
        return childPid
    }

    // MARK: - Stdout teeing

    private static func startStdoutTee(readPipeFD: Int32, capturePath: String) -> TeeSession {
        let captureFD = open(capturePath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        let teeThread = Thread {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let bytesRead = read(readPipeFD, &buffer, buffer.count)
                guard bytesRead > 0 else {
                    if bytesRead < 0 && errno == EINTR { continue }
                    break
                }
                writeAll(to: captureFD, buffer: buffer, count: bytesRead)
                writeIgnoringEPIPE(to: STDOUT_FILENO, buffer: buffer, count: bytesRead)
            }
        }
        teeThread.start()
        return TeeSession(thread: teeThread, captureFD: captureFD)
    }

    private static func writeAll(to fileDescriptor: Int32, buffer: [UInt8], count: Int) {
        guard fileDescriptor >= 0 else { return }
        var offset = 0
        while offset < count {
            let written = buffer.withUnsafeBytes { raw in
                write(fileDescriptor, raw.baseAddress! + offset, count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
    }

    private static func writeIgnoringEPIPE(to fileDescriptor: Int32, buffer: [UInt8], count: Int) {
        var offset = 0
        while offset < count {
            let written = buffer.withUnsafeBytes { raw in
                write(fileDescriptor, raw.baseAddress! + offset, count - offset)
            }
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
    }

    // MARK: - Status and records

    private static func waitForChildExit(childPid: pid_t) -> Int32 {
        var status: Int32 = 0
        while true {
            let res = waitpid(childPid, &status, 0)
            if res < 0 && errno == EINTR { continue }
            break
        }
        return status
    }

    private static func writeStartedRecord(spec: PassWrapperSpec, childPid: pid_t) throws {
        let identity = readStartIdentity(pid: childPid)
        let started = PassWrapperStarted(
            pid: childPid,
            processGroup: identity.processGroup,
            session: identity.session,
            startSeconds: identity.startSeconds,
            startMicroseconds: identity.startMicroseconds
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let startedData = try encoder.encode(started)
        try writeAtomic(data: startedData, to: URL(fileURLWithPath: spec.startedPath))
    }

    private static func writeStatusRecord(
        spec: PassWrapperSpec,
        status: Int32,
        receivedSignals: [Int32]
    ) throws -> PassWrapperStatus {
        let terminatingSignal = status & 0x7f
        let exitStatus: Int32? = (terminatingSignal == 0) ? ((status >> 8) & 0xff) : nil
        let signal: Int32? = (terminatingSignal != 0) ? terminatingSignal : nil

        let statusRecord = PassWrapperStatus(
            exitStatus: exitStatus,
            signal: signal,
            receivedSignals: receivedSignals
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let statusData = try encoder.encode(statusRecord)
        try writeAtomic(data: statusData, to: URL(fileURLWithPath: spec.statusPath))
        return statusRecord
    }

    private static func readStartIdentity(pid: pid_t) -> StartIdentity {
        for _ in 0..<50 {
            if let identity = ProcessTree.identity(of: pid) {
                return StartIdentity(
                    startSeconds: identity.startSeconds,
                    startMicroseconds: identity.startMicroseconds,
                    session: identity.session,
                    processGroup: identity.processGroup
                )
            }
            usleep(2000)
        }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let res = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, size)
        }
        if res == size {
            let session = getsid(pid)
            let pgid = pid_t(bitPattern: info.pbi_pgid)
            return StartIdentity(
                startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec,
                session: session > 0 ? session : pid,
                processGroup: pgid > 0 ? pgid : pid
            )
        }
        return StartIdentity(
            startSeconds: UInt64(Date().timeIntervalSince1970),
            startMicroseconds: 0,
            session: pid,
            processGroup: pid
        )
    }

    private static func cStringArray(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        var array = strings.map { strdup($0) }
        array.append(nil)
        return array
    }

    private static func freeCStringArray(_ array: [UnsafeMutablePointer<CChar>?]) {
        for pointer in array {
            free(pointer)
        }
    }
}
