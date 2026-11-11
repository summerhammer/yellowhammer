import Darwin
import Foundation

@_silgen_name("fork")
private func systemFork() -> pid_t

/// The small process boundary used by a terminal launcher. The launcher owns this process; the
/// engine reads its files and never waits for it. Kept as a hidden `yh` entry point so installs do
/// not need a second executable.
///
/// The launcher must create a fresh private directory per pass and use fresh identity, ending,
/// signal, stdout, and cancellation paths. Never reuse record paths across runs: records have no
/// cross-run token. SIGKILL and SIGSTOP cannot be caught or recorded by any process.
public enum PassWrapper {
    // POSIX setup must remain in one visible sequence so the fork boundary is auditable.
    // swiftlint:disable function_body_length cyclomatic_complexity
    /// Arguments: executable identity-file ending-file signal-file stdout-file cwd argv...
    /// Returns the CLI's status (or 128 + signal).
    public static func run(_ arguments: [String]) -> Int32 {
        guard arguments.count >= 6 else { return 64 }
        let executable = arguments[0]
        let identity = arguments[1]
        let ending = arguments[2]
        let signals = arguments[3]
        let output = arguments[4]
        let cwd = arguments[5]
        let cliArguments = Array(arguments.dropFirst(6))

        // Prepare every allocation and descriptor before fork. The child branch below uses only
        // libc calls until exec, because Swift runtime locks may be held by other threads.
        let identityTemporary = strdup("\(identity).tmp.\(getpid())")!
        let identityPath = strdup(identity)!
        let cancelPath = strdup("\(identity).cancel")!
        let cwdPath = strdup(cwd)!
        let executablePath = strdup(executable)!
        var argv = ([executable] + cliArguments).map { strdup($0) }
        argv.append(nil)
        defer {
            free(identityTemporary)
            free(identityPath)
            free(cancelPath)
            free(cwdPath)
            free(executablePath)
            argv.forEach { free($0) }
        }
        let wrapperPID = getpid()
        guard let wrapperStart = processStartTime(wrapperPID) else { return 71 }

        let signalFD = openDescriptor(signals, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard signalFD >= 0 else { return 73 }
        wrapperSignalFD = signalFD
        _ = fcntl(signalFD, F_SETFD, FD_CLOEXEC)
        var previousActions: [(Int32, sigaction)] = []
        var oldSignalMask = sigset_t()
        var changedSignalMask = false
        // SIGKILL and SIGSTOP cannot be caught; every other signal is observable and logged.
        for number in 1 ..< NSIG where number != SIGKILL && number != SIGSTOP {
            var action = sigaction()
            action.__sigaction_u = .init(__sa_sigaction: passWrapperSignalHandler)
            sigfillset(&action.sa_mask)
            action.sa_flags = SA_SIGINFO
            var previous = sigaction()
            if sigaction(number, &action, &previous) == 0 { previousActions.append((number, previous)) }
        }
        defer {
            var blockedMask = sigset_t()
            sigfillset(&blockedMask)
            _ = sigprocmask(SIG_SETMASK, &blockedMask, nil)
            wrapperSignalFD = -1
            for (number, var previous) in previousActions { _ = sigaction(number, &previous, nil) }
            close(signalFD)
            if changedSignalMask { _ = sigprocmask(SIG_SETMASK, &oldSignalMask, nil) }
        }
        var unblockedMask = sigset_t()
        sigemptyset(&unblockedMask)
        guard sigprocmask(SIG_SETMASK, &unblockedMask, &oldSignalMask) == 0 else { return 71 }
        changedSignalMask = true

        let outputFD = openDescriptor(output, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard outputFD >= 0 else { return 73 }
        defer { close(outputFD) }
        var execFailurePipe = [Int32](repeating: -1, count: 2)
        guard pipe(&execFailurePipe) == 0 else { return 71 }
        for index in execFailurePipe.indices where execFailurePipe[index] < 3 {
            let reserved = fcntl(execFailurePipe[index], F_DUPFD, 3)
            guard reserved >= 3 else {
                execFailurePipe.forEach { if $0 >= 0 { close($0) } }
                return 71
            }
            close(execFailurePipe[index])
            execFailurePipe[index] = reserved
        }
        var pipeReadFD = execFailurePipe[0]
        var pipeWriteFD = execFailurePipe[1]
        defer {
            if pipeReadFD >= 0 { close(pipeReadFD) }
            if pipeWriteFD >= 0 { close(pipeWriteFD) }
        }
        guard fcntl(pipeReadFD, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(pipeWriteFD, F_SETFD, FD_CLOEXEC) == 0 else { return 71 }
        let child = systemFork()
        guard child >= 0 else { return 71 }
        if child == 0 {
            close(pipeReadFD)
            resetChildSignals()
            wrapperSignalFD = -1
            guard setsid() == getpid(), chdir(cwdPath) == 0 else { _exit(126) }
            let nullFD = open("/dev/null", O_RDONLY)
            guard nullFD >= 0, dup2(nullFD, STDIN_FILENO) >= 0, dup2(outputFD, STDOUT_FILENO) >= 0 else { _exit(126) }
            if nullFD != STDIN_FILENO { close(nullFD) }
            if outputFD != STDOUT_FILENO { close(outputFD) }
            close(signalFD)
            writeIdentity(identityTemporary, identityPath, wrapperPID, wrapperStart)
            if access(cancelPath, F_OK) == 0 { unlink(identityPath); _exit(125) }
            execv(executablePath, &argv)
            let execError = errno
            withUnsafePointer(to: execError) { pointer in
                _ = writeFully(pipeWriteFD, UnsafeRawPointer(pointer), MemoryLayout<Int32>.size)
            }
            _exit(127)
        }
        close(pipeWriteFD)
        pipeWriteFD = -1
        var status: Int32 = 0
        while true {
            let waited = waitpid(child, &status, 0)
            if waited == child { break }
            if waited < 0 && errno == EINTR { continue }
            return 71
        }
        if readExecFailure(pipeReadFD) != nil { return 71 }
        let normalExit = status & 0x7f == 0
        let exitValue = normalExit ? (status >> 8) & 0xff : status & 0x7f
        let endingRecord = PassWrapperEnding(exited: normalExit, value: exitValue)
        guard writeEnding(ending, endingRecord) else { return 74 }
        return normalExit ? endingRecord.value : 128 + endingRecord.value
    }
    // swiftlint:enable function_body_length cyclomatic_complexity
}

nonisolated(unsafe) private var wrapperSignalFD: Int32 = -1

private func passWrapperSignalHandler(
    _ number: Int32, _ info: UnsafeMutablePointer<siginfo_t>?, _ context: UnsafeMutableRawPointer?
) {
    let saved = errno
    var timestamp = timespec()
    clock_gettime(CLOCK_REALTIME, &timestamp)
    var record = SignalRecord(
        signal: number, senderPID: info?.pointee.si_pid ?? 0,
        seconds: Int64(timestamp.tv_sec), microseconds: Int32(timestamp.tv_nsec / 1_000), reserved: 0
    )
    if wrapperSignalFD >= 0 {
        withUnsafeBytes(of: &record) { bytes in
            if let base = bytes.baseAddress { _ = write(wrapperSignalFD, base, bytes.count) }
        }
    }
    if number == SIGHUP || number == SIGTERM || number == SIGINT {
        errno = saved
        return
    }

    if number == SIGCHLD || number == SIGCONT || number == SIGURG || number == SIGWINCH
        || number == SIGINFO || number == SIGIO {
        errno = saved
        return
    }

    if number == SIGTSTP || number == SIGTTIN || number == SIGTTOU {
        // Stop signals suspend the wrapper after the handler returns. Keep this logger installed
        // so a later stop after SIGCONT is recorded too.
        _ = kill(getpid(), SIGSTOP)
        errno = saved
        return
    }

    // Keep the signal's ordinary effect after recording it. The three terminal-control signals
    // above are the only ones deliberately swallowed; e.g. SIGUSR1 still ends the wrapper.
    var defaultAction = sigaction()
    defaultAction.__sigaction_u = .init(__sa_handler: SIG_DFL)
    sigemptyset(&defaultAction.sa_mask)
    _ = sigaction(number, &defaultAction, nil)
    _ = kill(getpid(), number)
    errno = saved
}

private func resetChildSignals() {
    var defaultAction = sigaction()
    defaultAction.__sigaction_u = .init(__sa_handler: SIG_DFL)
    sigemptyset(&defaultAction.sa_mask)
    for number in 1 ..< NSIG where number != SIGKILL && number != SIGSTOP {
        _ = sigaction(number, &defaultAction, nil)
    }
    var emptyMask = sigset_t()
    sigemptyset(&emptyMask)
    _ = sigprocmask(SIG_SETMASK, &emptyMask, nil)
}

private struct SignalRecord {
    let signal: Int32
    let senderPID: Int32
    let seconds: Int64
    let microseconds: Int32
    let reserved: UInt32
}

/// Signal event with Unix timestamp; sender is nil when the kernel did not provide a PID.
public struct PassWrapperSignalEvent: Equatable, Sendable {
    public let signal: Int32
    public let senderPID: pid_t?
    public let seconds: Int64
    public let microseconds: Int32

    public static func readAll(from url: URL) -> [PassWrapperSignalEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let recordSize = MemoryLayout<SignalRecord>.size
        guard recordSize > 0 else { return [] }
        return stride(from: 0, to: data.count - data.count % recordSize, by: recordSize).compactMap { offset in
            var record = SignalRecord(signal: 0, senderPID: 0, seconds: 0, microseconds: 0, reserved: 0)
            withUnsafeMutableBytes(of: &record) { destination in
                _ = data.copyBytes(to: destination, from: offset ..< offset + recordSize)
            }
            guard record.signal != 0 else { return nil }
            return PassWrapperSignalEvent(
                signal: record.signal, senderPID: record.senderPID > 0 ? record.senderPID : nil,
                seconds: record.seconds, microseconds: record.microseconds
            )
        }
    }
}

private struct IdentityRecord {
    let magic: UInt64
    let version: UInt32
    let wrapperPID: Int32
    let wrapperSeconds: UInt64
    let wrapperMicroseconds: UInt64
    let pid: Int32
    let processGroup: Int32
    let session: Int32
    let reserved: UInt32
    let seconds: UInt64
    let microseconds: UInt64
}

/// Process identities published before the CLI executes. Identity is PID plus kernel start time.
public struct PassWrapperIdentity: Equatable, Sendable {
    public let wrapperPID: pid_t
    public let wrapperStartSeconds: UInt64
    public let wrapperStartMicroseconds: UInt64
    public let cliPID: pid_t
    public let processGroup: pid_t
    public let session: pid_t
    public let cliStartSeconds: UInt64
    public let cliStartMicroseconds: UInt64

    public static func read(from url: URL) -> PassWrapperIdentity? {
        guard let data = try? Data(contentsOf: url), data.count == MemoryLayout<IdentityRecord>.size else { return nil }
        var record = IdentityRecord(magic: 0, version: 0, wrapperPID: 0, wrapperSeconds: 0,
                                    wrapperMicroseconds: 0, pid: 0, processGroup: 0, session: 0,
                                    reserved: 0, seconds: 0, microseconds: 0)
        _ = withUnsafeMutableBytes(of: &record) { bytes in data.copyBytes(to: bytes) }
        guard record.magic == 0x5948504153534944, record.version == 1,
              record.wrapperPID > 0, record.pid > 0, record.processGroup == record.pid,
              record.session == record.pid else { return nil }
        return PassWrapperIdentity(
            wrapperPID: record.wrapperPID, wrapperStartSeconds: record.wrapperSeconds,
            wrapperStartMicroseconds: record.wrapperMicroseconds, cliPID: record.pid,
            processGroup: record.processGroup, session: record.session,
            cliStartSeconds: record.seconds, cliStartMicroseconds: record.microseconds
        )
    }
}

/// Parsed atomically published wrapper ending. A signal is distinct from an exit status.
public struct PassWrapperEnding: Equatable, Sendable {
    public let exited: Bool
    public let value: Int32
    fileprivate init(exited: Bool, value: Int32) { self.exited = exited; self.value = value }

    public static func read(from url: URL) -> PassWrapperEnding? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parts = contents.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, let value = Int32(parts[1]) else { return nil }
        return switch parts[0] {
        case "exit" where (0 ... 255).contains(value): PassWrapperEnding(exited: true, value: value)
        case "signal" where value > 0 && value < NSIG: PassWrapperEnding(exited: false, value: value)
        default: nil
        }
    }
}

private func writeIdentity(
    _ temporary: UnsafePointer<CChar>, _ path: UnsafePointer<CChar>, _ wrapperPID: pid_t,
    _ wrapperStart: (UInt64, UInt64)
) {
    var info = proc_bsdinfo()
    let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
    let received = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, pointer, infoSize)
    }
    guard received == infoSize, info.pbi_pid == UInt32(getpid()), info.pbi_status != UInt32(SZOMB) else {
        _exit(126)
    }
    var wrapperRecord = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(wrapperPID, PROC_PIDTBSDINFO, 0, &wrapperRecord, size) == size,
          wrapperRecord.pbi_start_tvsec == wrapperStart.0,
          wrapperRecord.pbi_start_tvusec == wrapperStart.1 else { _exit(126) }
    var record = IdentityRecord(
        magic: 0x5948504153534944, version: 1, wrapperPID: wrapperPID,
        wrapperSeconds: wrapperStart.0, wrapperMicroseconds: wrapperStart.1,
        pid: getpid(), processGroup: getpgrp(), session: getsid(0),
        reserved: 0,
        seconds: UInt64(info.pbi_start_tvsec), microseconds: UInt64(info.pbi_start_tvusec)
    )
    let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { _exit(126) }
    let fullSize = MemoryLayout<IdentityRecord>.size
    let written = withUnsafeBytes(of: &record) { bytes -> Int in
        guard let base = bytes.baseAddress else { return -1 }
        return writeFully(fd, base, bytes.count)
    }
    guard written == fullSize, fsync(fd) == 0 else { close(fd); unlink(temporary); _exit(126) }
    close(fd)
    if rename(temporary, path) != 0 { _exit(126) }
}

private func writeFully(_ fd: Int32, _ bytes: UnsafeRawPointer, _ count: Int) -> Int {
    var offset = 0
    while offset < count {
        let result = write(fd, bytes.advanced(by: offset), count - offset)
        if result < 0 && errno == EINTR { continue }
        guard result > 0 else { return -1 }
        offset += result
    }
    return offset
}

private func readExecFailure(_ fd: Int32) -> Int32? {
    var errorCode: Int32 = 0
    var offset = 0
    let bytesRead = withUnsafeMutableBytes(of: &errorCode) { bytes -> Int in
        guard let base = bytes.baseAddress else { return -1 }
        while offset < MemoryLayout<Int32>.size {
            let count = read(fd, base.advanced(by: offset), MemoryLayout<Int32>.size - offset)
            if count < 0 && errno == EINTR { continue }
            if count == 0 { return offset }
            guard count > 0 else { return -1 }
            offset += count
        }
        return offset
    }
    guard bytesRead == MemoryLayout<Int32>.size else { return bytesRead == 0 ? nil : -1 }
    return errorCode
}

private func openDescriptor(_ path: String, _ flags: Int32, _ mode: mode_t) -> Int32 {
    let descriptor = open(path, flags, mode)
    guard descriptor >= 0, descriptor < 3 else { return descriptor }
    let reserved = fcntl(descriptor, F_DUPFD, 3)
    close(descriptor)
    return reserved
}

private func processStartTime(_ pid: pid_t) -> (UInt64, UInt64)? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    let result = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size) }
    guard result == size, info.pbi_pid == UInt32(pid), info.pbi_status != UInt32(SZOMB) else { return nil }
    return (UInt64(info.pbi_start_tvsec), UInt64(info.pbi_start_tvusec))
}

private func writeEnding(_ path: String, _ result: PassWrapperEnding) -> Bool {
    atomicWrite("\(result.exited ? "exit" : "signal") \(result.value)\n", path: path)
}

private func atomicWrite(_ value: String, path: String) -> Bool {
    let temporary = "\(path).tmp.\(getpid())"
    let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { return false }
    let bytes = Array(value.utf8)
    let written = bytes.withUnsafeBytes { buffer -> Int in
        guard let base = buffer.baseAddress else { return -1 }
        return writeFully(fd, base, buffer.count)
    }
    let synced = fsync(fd) == 0
    close(fd)
    guard written == bytes.count, synced, rename(temporary, path) == 0 else {
        unlink(temporary)
        return false
    }
    return true
}
