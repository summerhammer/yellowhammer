import Domain
import Foundation
@testable import LinearAdapter
import Synchronization
import Testing

/// A `LinearTokenStore` backed by memory, recording every read/write and every time the refresh lock
/// was entered and exited (P17.3, ADR-005).
private final class FakeTokenStoreState: Sendable {
    private let pair: Mutex<LinearTokenPair?>
    let events = Mutex<[String]>([])
    private let writesLock = Mutex<[LinearTokenPair]>([])

    init(_ initial: LinearTokenPair?) {
        pair = Mutex(initial)
    }

    func read() -> LinearTokenPair? { pair.withLock { $0 } }

    func write(_ newValue: LinearTokenPair) {
        pair.withLock { $0 = newValue }
        writesLock.withLock { $0.append(newValue) }
        events.withLock { $0.append("write") }
    }

    var recordedWrites: [LinearTokenPair] { writesLock.withLock { $0 } }

    func store() -> LinearTokenStore {
        LinearTokenStore(
            read: { self.read() },
            write: { self.write($0) },
            withRefreshLock: { body in
                self.events.withLock { $0.append("enter") }
                defer { self.events.withLock { $0.append("exit") } }
                try await body()
            }
        )
    }
}

@Suite("Linear Installation token source (P17.3, ADR-005)")
struct LinearInstallationTokenSourceTests {
    private static func pair(
        accessToken: String, refreshToken: String = "refresh-1", secondsFromNow: TimeInterval, clock: ManualClock
    ) -> LinearTokenPair {
        LinearTokenPair(
            accessToken: accessToken, refreshToken: refreshToken,
            expiresAt: clock.read().addingTimeInterval(secondsFromNow)
        )
    }

    @Test("More than 2 hours remaining: no refresh, no store write")
    func noRefreshWhenFresh() async throws {
        let clock = ManualClock()
        let state = FakeTokenStoreState(Self.pair(accessToken: "access-1", secondsFromNow: 3 * 3600, clock: clock))
        let transport = StubHTTPTransport([])
        let source = LinearInstallationTokenSource(store: state.store(), transport: transport, clock: clock.read)

        let token = try await source.token()

        #expect(token == "access-1")
        #expect(transport.requests.isEmpty)
        #expect(state.recordedWrites.isEmpty)
    }

    @Test("Less than 2 hours remaining: refreshes, writes the store before returning, caches the rotated pair")
    func refreshesWhenNearExpiry() async throws {
        let clock = ManualClock()
        let state = FakeTokenStoreState(Self.pair(accessToken: "access-1", secondsFromNow: 3600, clock: clock))
        let transport = StubHTTPTransport([
            Fixture.installationGrant(accessToken: "access-2", refreshToken: "refresh-2", expiresIn: 7200)
        ])
        let source = LinearInstallationTokenSource(store: state.store(), transport: transport, clock: clock.read)

        let token = try await source.token()

        #expect(token == "access-2")
        #expect(transport.requests.count == 1)
        #expect(state.recordedWrites.count == 1)
        #expect(state.recordedWrites[0].accessToken == "access-2")
        #expect(state.recordedWrites[0].refreshToken == "refresh-2")
        let request = transport.requests[0]
        let requestData = try #require(request.httpBody)
        let body = try #require(String(data: requestData, encoding: .utf8))
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=refresh-1"))
        #expect(body.contains("client_id=\(LinearAppInstallation.clientID)"))

        // The store is written before the refreshed token is used again.
        let secondToken = try await source.token()
        #expect(secondToken == "access-2")
        #expect(transport.requests.count == 1, "the cached pair should be used, no second refresh")
    }

    @Test("Refresh runs inside the store's refresh lock")
    func refreshRunsInsideLock() async throws {
        let clock = ManualClock()
        let state = FakeTokenStoreState(Self.pair(accessToken: "access-1", secondsFromNow: 3600, clock: clock))
        let transport = StubHTTPTransport([
            Fixture.installationGrant(accessToken: "access-2", refreshToken: "refresh-2")
        ])
        let source = LinearInstallationTokenSource(store: state.store(), transport: transport, clock: clock.read)

        _ = try await source.token()

        #expect(state.events.withLock { $0 } == ["enter", "write", "exit"])
    }

    @Test("No stored pair: notAuthenticated naming the setup fix")
    func missingPairIsNotAuthenticated() async throws {
        let clock = ManualClock()
        let state = FakeTokenStoreState(nil)
        let transport = StubHTTPTransport([])
        let source = LinearInstallationTokenSource(store: state.store(), transport: transport, clock: clock.read)

        do {
            _ = try await source.token()
            Issue.record("expected a throw")
        } catch .notAuthenticated(let message) {
            #expect(message.contains("re-run the Linear step of yh setup"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("A legacy plaintext secret under the same reference is notAuthenticated, never unreachable")
    func legacyPlaintextSecretIsNotAuthenticated() async throws {
        let clock = ManualClock()
        let store = LinearTokenStore(
            read: {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: [], debugDescription: "plain secret, not a token pair")
                )
            },
            write: { _ in },
            withRefreshLock: { try await $0() }
        )
        let transport = StubHTTPTransport([])
        let source = LinearInstallationTokenSource(store: store, transport: transport, clock: clock.read)

        do {
            _ = try await source.token()
            Issue.record("expected a throw")
        } catch .notAuthenticated(let message) {
            #expect(message.contains("re-run the Linear step of yh setup"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("A revoked refresh token (400 invalid_request) is notAuthenticated")
    func revokedRefreshTokenIsNotAuthenticated() async throws {
        let clock = ManualClock()
        let state = FakeTokenStoreState(Self.pair(accessToken: "access-1", secondsFromNow: 3600, clock: clock))
        let transport = StubHTTPTransport([
            Fixture.json(#"{"error":"invalid_request","error_description":"Refresh token revoked"}"#, status: 400)
        ])
        let source = LinearInstallationTokenSource(store: state.store(), transport: transport, clock: clock.read)

        do {
            _ = try await source.token()
            Issue.record("expected a throw")
        } catch .notAuthenticated(let message) {
            #expect(message.contains("invalid_request"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("A 5xx refreshing is unreachable, not notAuthenticated")
    func refresh5xxIsUnreachable() async throws {
        let clock = ManualClock()
        let state = FakeTokenStoreState(Self.pair(accessToken: "access-1", secondsFromNow: 3600, clock: clock))
        let transport = StubHTTPTransport([Fixture.json("Server Error", status: 503)])
        let source = LinearInstallationTokenSource(store: state.store(), transport: transport, clock: clock.read)

        do {
            _ = try await source.token()
            Issue.record("expected a throw")
        } catch .unreachable {
            // Expected
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test("recoverFromUnauthorized: another process already refreshed — used without a token-endpoint call")
    func recoverUsesAlreadyRefreshedPair() async throws {
        let clock = ManualClock()
        let state = FakeTokenStoreState(Self.pair(accessToken: "access-2", secondsFromNow: 3600, clock: clock))
        let transport = StubHTTPTransport([])
        let source = LinearInstallationTokenSource(store: state.store(), transport: transport, clock: clock.read)

        let recovered = try await source.recoverFromUnauthorized(rejected: "access-1")

        #expect(recovered == "access-2")
        #expect(transport.requests.isEmpty)
    }

    @Test("recoverFromUnauthorized: the stored token is still the rejected one — forces a refresh regardless of TTL")
    func recoverForcesRefreshWhenStoreStillHoldsRejectedToken() async throws {
        let clock = ManualClock()
        // Plenty of time remaining — an ordinary token() call would not refresh — but the rejected
        // token proved stale, so recoverFromUnauthorized refreshes anyway.
        let state = FakeTokenStoreState(Self.pair(accessToken: "access-1", secondsFromNow: 5 * 3600, clock: clock))
        let transport = StubHTTPTransport([
            Fixture.installationGrant(accessToken: "access-2", refreshToken: "refresh-2")
        ])
        let source = LinearInstallationTokenSource(store: state.store(), transport: transport, clock: clock.read)

        let recovered = try await source.recoverFromUnauthorized(rejected: "access-1")

        #expect(recovered == "access-2")
        #expect(transport.requests.count == 1)
    }
}

@Suite("Linear Installation token source: refresh records")
struct TokenRefreshRecordTests {
    private static func state(
        secondsFromNow: TimeInterval, clock: ManualClock, accessToken: String = "access-1"
    ) -> FakeTokenStoreState {
        FakeTokenStoreState(LinearTokenPair(
            accessToken: accessToken, refreshToken: "refresh-1",
            expiresAt: clock.read().addingTimeInterval(secondsFromNow)
        ))
    }

    @Test("A near-expiry refresh that succeeds records one `refreshed` record with both expiries")
    func nearExpirySuccess() async throws {
        let clock = ManualClock()
        let state = Self.state(secondsFromNow: 3600, clock: clock)
        let log = AppInstallationTokenRefreshLog()
        let transport = StubHTTPTransport([
            Fixture.installationGrant(accessToken: "access-2", refreshToken: "refresh-2", expiresIn: 7200)
        ])
        let source = LinearInstallationTokenSource(
            store: state.store(), transport: transport, clock: clock.read, refreshLog: log
        )

        _ = try await source.token()

        let start = clock.read()
        #expect(log.drain() == [AppInstallationTokenRefresh(
            attemptedAt: start, trigger: .nearExpiry, previousExpiresAt: start.addingTimeInterval(3600),
            outcome: .refreshed(expiresAt: start.addingTimeInterval(7200))
        )])
        #expect(log.drain().isEmpty, "a record is handed out once")
    }

    @Test("A 401 invalid_client records one `refused` record with status, code and description")
    func refusedRecordsStatusCodeAndDescription() async throws {
        let clock = ManualClock()
        let state = Self.state(secondsFromNow: 60, clock: clock)
        let log = AppInstallationTokenRefreshLog()
        let transport = StubHTTPTransport([
            Fixture.json(
                #"{"error":"invalid_client","error_description":"Client authentication failed"}"#, status: 401
            )
        ])
        let source = LinearInstallationTokenSource(
            store: state.store(), transport: transport, clock: clock.read, refreshLog: log
        )

        do {
            _ = try await source.token()
            Issue.record("expected a throw")
        } catch .notAuthenticated(let message) {
            #expect(message.hasSuffix("HTTP 401 (invalid_client: Client authentication failed)"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }

        let records = log.drain()
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.trigger == .nearExpiry)
        guard case .refused(let refusal) = record.outcome else {
            Issue.record("expected refused")
            return
        }
        #expect(refusal.status == 401)
        #expect(refusal.code == "invalid_client")
        #expect(refusal.description == "Client authentication failed")
        #expect(refusal.message.contains("invalid_client: Client authentication failed"))
    }

    @Test("A transport failure records `refused` with no status")
    func transportFailureHasNoStatus() async throws {
        let clock = ManualClock()
        let state = Self.state(secondsFromNow: 60, clock: clock)
        let log = AppInstallationTokenRefreshLog()
        let transport = StubHTTPTransport([.failure(.notConnectedToInternet)])
        let source = LinearInstallationTokenSource(
            store: state.store(), transport: transport, clock: clock.read, refreshLog: log
        )

        _ = try? await source.token()

        guard case .unreachable(let message)? = log.drain().first?.outcome else {
            Issue.record("expected unreachable")
            return
        }
        #expect(message.contains("could not be reached"))
    }

    @Test("A 2xx with an unreadable body records `notStored`, not a refusal")
    func unreadableBodyIsNotStored() async throws {
        let clock = ManualClock()
        let log = AppInstallationTokenRefreshLog()
        let source = LinearInstallationTokenSource(
            store: Self.state(secondsFromNow: 60, clock: clock).store(),
            transport: StubHTTPTransport([Fixture.json("not json at all", status: 200)]),
            clock: clock.read, refreshLog: log
        )

        _ = try? await source.token()

        guard case .notStored(let message)? = log.drain().first?.outcome else {
            Issue.record("expected notStored")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test("A 2xx whose new pair cannot be written records `notStored`")
    func storeWriteFailureIsNotStored() async throws {
        struct WriteFailed: Error {}
        let clock = ManualClock()
        let log = AppInstallationTokenRefreshLog()
        let original = LinearTokenPair(
            accessToken: "access-1", refreshToken: "refresh-1",
            expiresAt: clock.read().addingTimeInterval(60)
        )
        let store = LinearTokenStore(
            read: { original }, write: { _ in throw WriteFailed() }, withRefreshLock: { body in try await body() }
        )
        let source = LinearInstallationTokenSource(
            store: store,
            transport: StubHTTPTransport([Fixture.installationGrant(accessToken: "a2", refreshToken: "r2")]),
            clock: clock.read, refreshLog: log
        )

        _ = try? await source.token()

        let records = log.drain()
        #expect(records.count == 1)
        guard case .notStored(let message)? = records.first?.outcome else {
            Issue.record("expected notStored")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test("The forced path after a rejected access token records trigger access-token-rejected")
    func forcedPathTrigger() async throws {
        let clock = ManualClock()
        let state = Self.state(secondsFromNow: 5 * 3600, clock: clock)
        let log = AppInstallationTokenRefreshLog()
        let transport = StubHTTPTransport([
            Fixture.installationGrant(accessToken: "access-2", refreshToken: "refresh-2")
        ])
        let source = LinearInstallationTokenSource(
            store: state.store(), transport: transport, clock: clock.read, refreshLog: log
        )

        _ = try await source.recoverFromUnauthorized(rejected: "access-1")

        let records = log.drain()
        #expect(records.count == 1)
        #expect(records.first?.trigger == .accessTokenRejected)
    }

    @Test("No refresh needed records nothing; a nil log breaks nothing")
    func noRefreshNoRecord() async throws {
        let clock = ManualClock()
        let log = AppInstallationTokenRefreshLog()
        let fresh = LinearInstallationTokenSource(
            store: Self.state(secondsFromNow: 5 * 3600, clock: clock).store(),
            transport: StubHTTPTransport([]), clock: clock.read, refreshLog: log
        )
        _ = try await fresh.token()
        #expect(log.drain().isEmpty)

        let unlogged = LinearInstallationTokenSource(
            store: Self.state(secondsFromNow: 60, clock: clock).store(),
            transport: StubHTTPTransport([Fixture.installationGrant(accessToken: "a2", refreshToken: "r2")]),
            clock: clock.read
        )
        #expect(try await unlogged.token() == "a2")
    }

    @Test("No record or stored payload carries an old or new token, even when Linear echoes one")
    func recordsCarryNoTokens() async throws {
        let clock = ManualClock()
        let log = AppInstallationTokenRefreshLog()
        let echoed = Self.state(secondsFromNow: 60, clock: clock, accessToken: "old-access-secret")
        let refused = LinearInstallationTokenSource(
            store: echoed.store(),
            transport: StubHTTPTransport([Fixture.json(
                #"{"error":"invalid_grant","error_description":"bad old-access-secret and refresh-1"}"#, status: 400
            )]),
            clock: clock.read, refreshLog: log
        )
        _ = try? await refused.token()
        let succeeded = LinearInstallationTokenSource(
            store: Self.state(secondsFromNow: 60, clock: clock, accessToken: "old-access-secret").store(),
            transport: StubHTTPTransport([
                Fixture.installationGrant(accessToken: "new-access-secret", refreshToken: "new-refresh-secret")
            ]),
            clock: clock.read, refreshLog: log
        )
        _ = try await succeeded.token()

        let text = String(describing: log.drain())
        #expect(text.contains("<redacted>"))
        for secret in ["old-access-secret", "refresh-1", "new-access-secret", "new-refresh-secret"] {
            #expect(!text.contains(secret), "\(secret) leaked into a refresh record")
        }
    }
}
