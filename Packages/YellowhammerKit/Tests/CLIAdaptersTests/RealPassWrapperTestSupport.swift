import Darwin
import CLIAdapters
import Foundation
import ProcessTestSupport

nonisolated(unsafe) private var passWrapperHarnessDirectoryAtExit: String?

private func removePassWrapperHarnessDirectoryAtExit() {
    if let path = passWrapperHarnessDirectoryAtExit {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// Compiles a tiny test-only entry point with the production wrapper source. Invoking this helper
/// keeps `fork()` out of the multithreaded Swift Testing process while still exercising the exact
/// implementation used by `yh --_pass-wrapper`.
enum RealPassWrapperHarness {
    static let executable: URL = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yh-pass-wrapper-harness-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fatalError("could not create wrapper harness directory: \(error)")
        }

        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let wrapperSource = packageRoot.appendingPathComponent("Sources/CLIAdapters/PassWrapper.swift")
        let mainSource = directory.appendingPathComponent("main.swift")
        let executable = directory.appendingPathComponent("pass-wrapper")
        let compilerLog = directory.appendingPathComponent("swiftc.log")
        let main = """
            import Darwin
            import Foundation
            @main struct TestPassWrapperMain {
                static func main() {
                    Darwin.exit(PassWrapper.run(Array(CommandLine.arguments.dropFirst())))
                }
            }
            """
        do {
            try main.write(to: mainSource, atomically: true, encoding: .utf8)
        } catch {
            fatalError("could not write wrapper harness source: \(error)")
        }

        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", "-swift-version", "6", "-parse-as-library", wrapperSource.path,
                              mainSource.path, "-o", executable.path]
        if let handle = try? FileHandle(forWritingTo: compilerLog) {
            compiler.standardOutput = handle
            compiler.standardError = handle
        } else {
            FileManager.default.createFile(atPath: compilerLog.path, contents: nil)
            compiler.standardOutput = FileHandle(forWritingAtPath: compilerLog.path)
            compiler.standardError = compiler.standardOutput
        }
        do {
            try compiler.run()
            compiler.waitUntilExit()
        } catch {
            fatalError("could not run swiftc for wrapper harness: \(error)")
        }
        guard compiler.terminationStatus == 0 else {
            let log = (try? String(contentsOf: compilerLog, encoding: .utf8)) ?? "(no compiler output)"
            fatalError("swiftc failed to build production PassWrapper.swift:\n\(log)")
        }
        try? FileManager.default.removeItem(at: compilerLog)
        try? FileManager.default.removeItem(at: mainSource)
        passWrapperHarnessDirectoryAtExit = directory.path
        atexit(removePassWrapperHarnessDirectoryAtExit)
        return executable
    }()

    static func makeFixture(script: String, arguments: [String] = []) throws -> RealPassWrapperFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yh-real-pass-wrapper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let worktree = directory.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let cli = directory.appendingPathComponent("cli.sh")
        try ("#!/bin/sh\nset -eu\n" + script + "\n").write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return RealPassWrapperFixture(
            directory: directory, worktree: worktree, cli: cli, arguments: [directory.path] + arguments
        )
    }
}

final class RealPassWrapperFixture: @unchecked Sendable {
    let directory: URL
    let worktree: URL
    let cli: URL
    let arguments: [String]
    let identityFile: URL
    let endingFile: URL
    let signalFile: URL
    let stdoutFile: URL
    private(set) var wrapper: SpawnedChild?
    private var trackedProcesses: [TestProcessIdentity] = []

    init(directory: URL, worktree: URL, cli: URL, arguments: [String]) {
        self.directory = directory
        self.worktree = worktree
        self.cli = cli
        self.arguments = arguments
        identityFile = directory.appendingPathComponent("identity")
        endingFile = directory.appendingPathComponent("ending")
        signalFile = directory.appendingPathComponent("signals")
        stdoutFile = directory.appendingPathComponent("stdout")
    }

    @discardableResult
    func launch() throws -> SpawnedChild {
        let process = try SpawnedChild.spawn(
            executable: RealPassWrapperHarness.executable.path,
            arguments: [cli.path, identityFile.path, endingFile.path, signalFile.path,
                        stdoutFile.path, worktree.path] + arguments,
            currentDirectory: directory
        )
        wrapper = process
        return process
    }

    func read(_ name: String) -> String? {
        try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    func pid(in name: String) -> pid_t? {
        guard let value = read(name) else { return nil }
        return pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func track(_ pid: pid_t) {
        if let identity = testProcessIdentity(pid), !trackedProcesses.contains(where: { $0.pid == pid }) {
            trackedProcesses.append(identity)
        }
    }

    /// Reaps the wrapper and kills its process group plus fixture-recorded escaped children even
    /// when an assertion or monitor path failed early.
    func cleanUp() {
        wrapper?.terminateAndReap()
        if let identity = PassWrapperIdentity.read(from: identityFile),
           let current = testProcessIdentity(identity.cliPID),
           current.startSeconds == identity.cliStartSeconds,
           current.startMicroseconds == identity.cliStartMicroseconds,
           current.processGroup == identity.processGroup {
            _ = kill(-identity.processGroup, SIGKILL)
        }
        for process in trackedProcesses {
            guard let current = testProcessIdentity(process.pid),
                  current.startSeconds == process.startSeconds,
                  current.startMicroseconds == process.startMicroseconds else { continue }
            _ = kill(process.pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct TestProcessIdentity {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let processGroup: pid_t
}

private func testProcessIdentity(_ pid: pid_t) -> TestProcessIdentity? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
          info.pbi_status != UInt32(SZOMB) else { return nil }
    return TestProcessIdentity(
        pid: pid, startSeconds: UInt64(info.pbi_start_tvsec),
        startMicroseconds: UInt64(info.pbi_start_tvusec), processGroup: pid_t(bitPattern: info.pbi_pgid)
    )
}

func awaitPassWrapperFile(_ url: URL, timeout: Duration = .seconds(5)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return FileManager.default.fileExists(atPath: url.path)
}

func awaitPassWrapperDead(_ pid: pid_t, timeout: Duration = .seconds(3)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        var info = proc_bsdinfo()
        let found = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(MemoryLayout<proc_bsdinfo>.size))
        }
        if found != Int32(MemoryLayout<proc_bsdinfo>.size) || info.pbi_status == UInt32(SZOMB) { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

func awaitPassWrapperStopped(_ pid: pid_t, timeout: Duration = .seconds(3)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        var info = proc_bsdinfo()
        let found = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(MemoryLayout<proc_bsdinfo>.size))
        }
        if found == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_status == UInt32(SSTOP) { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}
