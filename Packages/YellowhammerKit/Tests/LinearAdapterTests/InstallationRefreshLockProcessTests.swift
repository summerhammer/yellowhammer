import Config
import Domain
@testable import LinearAdapter
import Foundation
import Synchronization
import Testing

// One refresh lock per App Installation (roadmap L1.2; install-the-linear-app, *Keeping it alive*;
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
private final class RefreshingChild: @unchecked Sendable {
    private let process = Process()
    private let outputPipe = Pipe()

    init(lockPath: URL, holdSeconds: Double, pairPath: URL? = nil, rotatedPair: String? = nil) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
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
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
    }

    var isRunning: Bool { process.isRunning }

    /// Starts the child and blocks (bounded) until it reports holding the lock.
    func startAndWaitUntilLocked(timeout: Duration = .seconds(10)) throws {
        try process.run()
        let handle = outputPipe.fileHandleForReading
        let deadline = ContinuousClock.now + timeout
        var buffer = Data()
        while !buffer.contains(UInt8(ascii: "\n")) {
            guard ContinuousClock.now < deadline else {
                throw ChildFailure("the refreshing child never reported holding the lock")
            }
            let chunk = handle.availableData
            if chunk.isEmpty {
                usleep(5_000)
                continue
            }
            buffer.append(chunk)
        }
    }

    func terminateAndWait() {
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
    }
}

private struct ChildFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@Suite("One refresh lock per App Installation, across processes (L1.2, OQ109 item 8)")
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
        // An acme Act holding its lock far longer than the beta refresh below can take.
        let child = RefreshingChild(lockPath: acmeLock, holdSeconds: 20)
        try child.startAndWaitUntilLocked()
        defer { child.terminateAndWait() }

        let betaPair = home.appending(component: "beta-pair.json", directoryHint: .notDirectory)
        try stalePair.encoded().write(to: betaPair, atomically: true, encoding: .utf8)
        let endpoint = CountingTokenEndpoint()
        let source = LinearInstallationTokenSource(
            store: tokenStore(pairFile: betaPair, lock: MachineLock(fileURL: betaLock)),
            transport: endpoint, clock: { now }
        )

        let start = ContinuousClock.now
        let token = try await source.token()
        let elapsed = start.duration(to: .now)

        #expect(token == "access-mine")
        #expect(endpoint.requestCount == 1)
        // Generous: a parallel suite run queues work, but nothing near the child's 20 s hold.
        #expect(elapsed < .seconds(10), "beta's refresh waited on acme's lock")
        #expect(child.isRunning, "acme's lock must still have been held throughout")
    }
}
