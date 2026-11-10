import CLIAdapters
import Darwin
import Domain
import Foundation
import Testing

final class WrappedTestBundleAnchor {}

func wrappedProductsDirectory() -> URL {
    let bundle = Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" }
        ?? Bundle(for: WrappedTestBundleAnchor.self)
    return bundle.bundleURL.deletingLastPathComponent()
}

func passWrapperChildURL() throws -> URL {
    let executable = wrappedProductsDirectory().appending(component: "PassWrapperChild")
    try #require(
        FileManager.default.isExecutableFile(atPath: executable.path),
        "PassWrapperChild is not built at \(executable.path); run `swift build --build-tests`"
    )
    return executable
}

func spawnLauncherInFreshSession(launcherURL: URL) throws -> pid_t {
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }

    let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
    posix_spawnattr_setflags(&attr, Int16(flags))

    let executable = "/bin/bash"
    let argv = [strdup(executable), strdup(launcherURL.path), nil]
    defer {
        for ptr in argv where ptr != nil { free(ptr) }
    }

    var pid: pid_t = 0
    let rc = posix_spawn(&pid, executable, nil, &attr, argv, nil)
    guard rc == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EIO)
    }
    return pid
}

final class PIDTracker: @unchecked Sendable {
    private var pids: [pid_t] = []
    private let lock = NSLock()

    var first: pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return pids.first
    }

    func add(_ pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        pids.append(pid)
    }

    func reapAll() {
        lock.lock()
        defer { lock.unlock() }
        for pid in pids {
            waitpid(pid, nil, WNOHANG)
        }
    }
}

extension RunOutcome {
    var isWrappedCompleted: Bool {
        if case .completed = self { return true }
        return false
    }
}

func awaitFile(_ url: URL, timeout: Duration = .seconds(5)) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if FileManager.default.fileExists(atPath: url.path) { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(FileManager.default.fileExists(atPath: url.path), "timed out waiting for \(url.path)")
}

func awaitDead(_ pid: pid_t, timeout: Duration = .seconds(5)) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if kill(pid, 0) != 0 { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
}
