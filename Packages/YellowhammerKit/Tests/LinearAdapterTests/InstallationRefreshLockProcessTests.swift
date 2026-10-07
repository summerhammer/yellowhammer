import Config
import Darwin
import Domain
@testable import LinearAdapter
import Foundation
import Synchronization
import Testing

// One refresh lock per Board Connection (roadmap L1.2; install-the-linear-app, *Keeping it alive*;
// OQ109 item 8), across real processes. A child process plays another Act's refresh: it flocks a lock
// file, and may write a rotated pair to a file-backed token store before releasing. This process runs
// a real `LinearInstallationTokenSource` whose refresh lock is a `MachineLock` at the path
// `MachineLock.defaultFileURL(homeDirectory:installation:)` gives — so what is asserted is the keying,
// not merely two arbitrary lock files.

/// Counts token-endpoint requests and answers each with a fresh grant.
private final class CountingTokenEndpoint: HTTPTransport, Sendable {
    private let requests = Mutex<Int>(0)

    var requestCount: Int { requests.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.withLock { $0 += 1 }
        let body = Data(#"{"access_token":"access-mine","refresh_token":"refresh-mine","expires_in":7200}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (body, response)
    }
}

/// Another process's refresh: flocks `lockPath`, reports `locked`, holds it `holdSeconds`, then — when
/// given one — writes `rotatedPair` to `pairPath` (its own token request and Keychain write) and exits,
/// releasing the lock.
private final class RefreshingChild {
    private let arguments: [String]
    private let readinessPath: String
    private var pid: pid_t?

    init(lockPath: URL, holdSeconds: Double, pairPath: URL? = nil, rotatedPair: String? = nil) {
        readinessPath = lockPath.deletingLastPathComponent()
            .appendingPathComponent("refresh-ready-\(UUID().uuidString)").path
        arguments = [
            "-c",
            """
            import fcntl, sys, time
            lock = open(sys.argv[1], "a")
            fcntl.flock(lock, fcntl.LOCK_EX)
            print("locked", flush=True)
            time.sleep(float(sys.argv[2]))
            if len(sys.argv) > 4:
                with open(sys.argv[3], "w") as pair:
                    pair.write(sys.argv[4])
            """,
            lockPath.path, String(holdSeconds)
        ] + [pairPath?.path, rotatedPair].compactMap { $0 }
    }

    var isRunning: Bool { !reapIfExited() }

    /// File-backed readiness keeps the ten-second deadline effective even if the child prints nothing.
    func startAndWaitUntilLocked(timeout: Duration = .seconds(10)) throws {
        let output = open(readinessPath, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw ChildFailure("could not create the refreshing child's readiness file") }
        defer {
            close(output)
            unlink(readinessPath)
        }
        do {
            pid = try spawn(output: output)
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if try hasReportedLock(output: output) { return }
                guard !reapIfExited() else {
                    throw ChildFailure("the refreshing child exited before reporting that it held the lock")
                }
                usleep(5_000)
            }
            throw ChildFailure("the refreshing child never reported holding the lock within \(timeout)")
        } catch {
            // A failure happens before the test installs its defer, so this method owns that cleanup.
            terminateAndWait()
            throw error
        }
    }

    /// Reap our exact PID directly; Foundation's shared Process bookkeeping cannot strand this fixture.
    func terminateAndWait() {
        guard !reapIfExited(), let pid else { return }
        kill(-pid, SIGTERM)
        if waitUntilReaped(deadline: ContinuousClock.now + .milliseconds(150)) { return }
        kill(-pid, SIGKILL)
        if !waitUntilReaped(deadline: ContinuousClock.now + .seconds(1)) {
            Issue.record("the refreshing child \(pid) could not be reaped after SIGKILL")
        }
    }

    private func hasReportedLock(output: Int32) throws -> Bool {
        var bytes = [UInt8](repeating: 0, count: 64)
        let count = pread(output, &bytes, bytes.count, 0)
        if count < 0 {
            if errno == EINTR { return false }
            throw ChildFailure("could not read the refreshing child's readiness file")
        }
        let output = bytes.prefix(count)
        guard output.contains(UInt8(ascii: "\n")) else { return false }
        guard String(bytes: output, encoding: .utf8) == "locked\n" else {
            throw ChildFailure("the refreshing child returned an invalid readiness marker")
        }
        return true
    }

    private func reapIfExited() -> Bool {
        guard let pid else { return true }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid || (result < 0 && errno == ECHILD) {
            self.pid = nil
            return true
        }
        return false
    }

    private func waitUntilReaped(deadline: ContinuousClock.Instant) -> Bool {
        while ContinuousClock.now < deadline {
            if reapIfExited() { return true }
            usleep(5_000)
        }
        return reapIfExited()
    }

    private func spawn(output: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try checked(posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO))
        try checked(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0))
        try checked(posix_spawn_file_actions_addclose(&actions, output))
        var attributes: posix_spawnattr_t?
        try checked(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        try checked(posix_spawnattr_setflags(&attributes, Int16(flags)))
        try checked(posix_spawnattr_setpgroup(&attributes, 0))
        var defaults = sigset_t()
        sigfillset(&defaults)
        try checked(posix_spawnattr_setsigdefault(&attributes, &defaults))
        var mask = sigset_t()
        sigemptyset(&mask)
        try checked(posix_spawnattr_setsigmask(&attributes, &mask))
        let argv = (["/usr/bin/python3"] + arguments).map { strdup($0) } + [nil]
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        try checked(posix_spawn(&pid, "/usr/bin/python3", &actions, &attributes, argv, envp))
        return pid
    }

    private func checked(_ result: Int32) throws {
        if result != 0 {
            throw ChildFailure("could not spawn the refreshing child: \(String(cString: strerror(result)))")
        }
    }
}

private struct ChildFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@Suite("One refresh lock per Board Connection, across processes (L1.2, OQ109 item 8)")
struct InstallationRefreshLockProcessTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A temporary home with `~/.config/yellowhammer` created, so the child can open its lock file
    /// before this process's `MachineLock` ever has.
    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appending(component: "yh-lock-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: home.appending(components: ".config", "yellowhammer"), withIntermediateDirectories: true
        )
        return home
    }

    /// The pair file the token store reads and writes — the Keychain's stand-in, visible to the child.
    private func tokenStore(pairFile: URL, lock: MachineLock) -> LinearTokenStore {
        LinearTokenStore(
            read: {
                guard let json = try? String(contentsOf: pairFile, encoding: .utf8) else { return nil }
                return try LinearTokenPair(storedJSON: json)
            },
            write: { pair in try pair.encoded().write(to: pairFile, atomically: true, encoding: .utf8) },
            withRefreshLock: { body in
                do {
                    try await lock.withLock(body)
                } catch let error as MachineLockError {
                    if case .bodyFailed(let inner) = error { throw inner }
                    throw error
                }
            }
        )
    }

    /// Less than the two-hour refresh window left: an Act holding this pair must refresh.
    private var stalePair: LinearTokenPair {
        LinearTokenPair(
            accessToken: "access-stale", refreshToken: "refresh-stale", expiresAt: now.addingTimeInterval(3600)
        )
    }

    @Test("A readiness timeout cleans up the child waiting for the refresh lock")
    func readinessTimeoutCleansChild() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let lockPath = MachineLock.defaultFileURL(homeDirectory: home, installation: "acme")
        let holder = RefreshingChild(lockPath: lockPath, holdSeconds: 300)
        try holder.startAndWaitUntilLocked()
        defer { holder.terminateAndWait() }
        let waiter = RefreshingChild(lockPath: lockPath, holdSeconds: 300)
        #expect(throws: ChildFailure.self) {
            try waiter.startAndWaitUntilLocked(timeout: .milliseconds(100))
        }
        #expect(!waiter.isRunning)
        #expect(holder.isRunning)
    }

    @Test("Two processes on one installation make one token request: the waiter re-reads the rotated pair")
    func sameInstallationMakesOneRequest() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let pairFile = home.appending(component: "acme-pair.json", directoryHint: .notDirectory)
        try stalePair.encoded().write(to: pairFile, atomically: true, encoding: .utf8)
        let rotated = LinearTokenPair(
            accessToken: "access-other", refreshToken: "refresh-other", expiresAt: now.addingTimeInterval(3 * 3600)
        )

        let acmeLock = MachineLock.defaultFileURL(homeDirectory: home, installation: "acme")
        #expect(acmeLock.lastPathComponent == "linear-token-acme.lock")
        // The other process's refresh: it holds acme's lock while its one token request is in flight,
        // then stores the rotated pair and releases.
        let child = RefreshingChild(
            lockPath: acmeLock, holdSeconds: 1.0, pairPath: pairFile, rotatedPair: try rotated.encoded()
        )
        try child.startAndWaitUntilLocked()
        defer { child.terminateAndWait() }

        let endpoint = CountingTokenEndpoint()
        let source = LinearInstallationTokenSource(
            store: tokenStore(
                pairFile: pairFile,
                lock: MachineLock(fileURL: MachineLock.defaultFileURL(homeDirectory: home, installation: "acme"))
            ),
            transport: endpoint, clock: { now }
        )
        let token = try await source.token()

        #expect(token == "access-other", "the waiter must use the pair the other process stored")
        #expect(endpoint.requestCount == 0, "the other process's request is the only one: this one must not refresh")
        #expect(try LinearTokenPair(storedJSON: String(contentsOf: pairFile, encoding: .utf8)) == rotated)
    }

    @Test("Processes on two installations never wait on each other's lock")
    func twoInstallationsNeverWait() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let acmeLock = MachineLock.defaultFileURL(homeDirectory: home, installation: "acme")
        let betaLock = MachineLock.defaultFileURL(homeDirectory: home, installation: "beta")
        #expect(acmeLock.lastPathComponent == "linear-token-acme.lock")
        #expect(betaLock.lastPathComponent == "linear-token-beta.lock")
        // An acme Act holding its lock far longer than any parallel suite run takes. The child is
        // terminated in the defer, so the hold bounds only a regression, never a passing run.
        let child = RefreshingChild(lockPath: acmeLock, holdSeconds: 300)
        try child.startAndWaitUntilLocked()
        defer { child.terminateAndWait() }

        let betaPair = home.appending(component: "beta-pair.json", directoryHint: .notDirectory)
        try stalePair.encoded().write(to: betaPair, atomically: true, encoding: .utf8)
        let endpoint = CountingTokenEndpoint()
        let source = LinearInstallationTokenSource(
            store: tokenStore(pairFile: betaPair, lock: MachineLock(fileURL: betaLock)),
            transport: endpoint, clock: { now }
        )

        let token = try await source.token()

        #expect(token == "access-mine")
        #expect(endpoint.requestCount == 1)
        // No wall-clock bound: a parallel run queues every test for tens of seconds. The child
        // releases acme's lock only by exiting, so it still running proves beta never waited on it.
        #expect(child.isRunning, "beta's refresh waited on acme's lock")
    }
}
