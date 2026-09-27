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
