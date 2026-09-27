import Domain
import Foundation
@testable import LinearAdapter
import Synchronization
import Testing

/// A `LinearTokenStore` whose `read`/`write` are recorded, for `LinearAdapter.send`'s one-retry-after-a
/// -forced-refresh path (P17.3, ADR-005).
private final class FakeInstallationStore: Sendable {
    private let pair: Mutex<LinearTokenPair?>
    private let refreshCalls = Mutex<Int>(0)
    /// How many requests the transport had already sent at the moment each write happened — so a test
    /// can assert the store was written before the refreshed token went out on the retry, not merely
    /// that it was written at some point.
    private let requestCountsAtWrite = Mutex<[Int]>([])

    init(_ initial: LinearTokenPair) {
        pair = Mutex(initial)
    }

    var refreshCallCount: Int { refreshCalls.withLock { $0 } }
    var requestCountsWhenWritten: [Int] { requestCountsAtWrite.withLock { $0 } }

    func store(transport: StubHTTPTransport) -> LinearTokenStore {
        LinearTokenStore(
            read: { self.pair.withLock { $0 } },
            write: { newValue in
                self.refreshCalls.withLock { $0 += 1 }
                self.requestCountsAtWrite.withLock { $0.append(transport.requests.count) }
                self.pair.withLock { $0 = newValue }
            },
            withRefreshLock: { try await $0() }
        )
    }
}

@Suite("LinearAdapter.send recovers from one unauthorized response (P17.3, ADR-005)")
struct LinearAdapterInstallationSendTests {
    private static func adapter(
        _ transport: StubHTTPTransport, store: FakeInstallationStore, clock: ManualClock = ManualClock()
    ) -> LinearAdapter {
        LinearAdapter(
            linearProjectID: Fixture.linearProjectID, tokenStore: store.store(transport: transport),
            transport: transport, clock: clock.read
        )
    }

    private static func startingPair(_ clock: ManualClock) -> LinearTokenPair {
        LinearTokenPair(
            accessToken: "access-1", refreshToken: "refresh-1", expiresAt: clock.read().addingTimeInterval(5 * 3600)
        )
    }

    @Test("A single 401 triggers exactly one forced refresh and one retry, which then succeeds")
    func singleUnauthorizedRecoversOnce() async throws {
        let clock = ManualClock()
        let store = FakeInstallationStore(Self.startingPair(clock))
        let transport = StubHTTPTransport([
            Fixture.json(#"{"errors":[]}"#, status: 401),
            Fixture.installationGrant(accessToken: "access-2", refreshToken: "refresh-2"),
            Fixture.viewer
        ])
        let adapter = Self.adapter(transport, store: store, clock: clock)

        let identity = try await adapter.identity()

        #expect(identity.name == "Yellowhammer")
        #expect(store.refreshCallCount == 1)
        #expect(transport.requests.count == 3)
        // The retry carries the refreshed token, not the rejected one.
        #expect(transport.requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer access-2")
        // Written after the 401 and the refresh POST (2 requests sent), strictly before the retry (which
        // would be the 3rd request) — Linear rotates the refresh token, so writing after using it would
        // strand the stored one on a crash between the two.
        #expect(store.requestCountsWhenWritten == [2])
    }

    @Test("A second 401 on the retry throws notAuthenticated after exactly one refresh — never a loop")
    func repeatedUnauthorizedThrowsAfterOneRefresh() async throws {
        let clock = ManualClock()
        let store = FakeInstallationStore(Self.startingPair(clock))
        let transport = StubHTTPTransport([
            Fixture.json(#"{"errors":[]}"#, status: 401),
            Fixture.installationGrant(accessToken: "access-2", refreshToken: "refresh-2"),
            Fixture.json(#"{"errors":[]}"#, status: 401)
        ])
        let adapter = Self.adapter(transport, store: store, clock: clock)

        do {
            _ = try await adapter.identity()
            Issue.record("expected a throw")
        } catch .notAuthenticated {
            // Expected
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(store.refreshCallCount == 1)
        #expect(transport.requests.count == 3)
    }

    @Test("A GraphQL FORBIDDEN code never triggers a refresh")
    func forbiddenCodeNeverRefreshes() async throws {
        let clock = ManualClock()
        let store = FakeInstallationStore(Self.startingPair(clock))
        let transport = StubHTTPTransport([
            Fixture.json(#"{"errors":[{"message":"nope","extensions":{"code":"FORBIDDEN"}}]}"#)
        ])
        let adapter = Self.adapter(transport, store: store, clock: clock)

        do {
            _ = try await adapter.identity()
            Issue.record("expected a throw")
        } catch .forbidden {
            // Expected
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(store.refreshCallCount == 0)
        #expect(transport.requests.count == 1)
    }

    @Test("An HTTP 403 never triggers a refresh")
    func http403NeverRefreshes() async throws {
        let clock = ManualClock()
        let store = FakeInstallationStore(Self.startingPair(clock))
        let transport = StubHTTPTransport([Fixture.json(#"{"errors":[]}"#, status: 403)])
        let adapter = Self.adapter(transport, store: store, clock: clock)

        do {
            _ = try await adapter.identity()
            Issue.record("expected a throw")
        } catch .forbidden {
            // Expected
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
        #expect(store.refreshCallCount == 0)
        #expect(transport.requests.count == 1)
    }
}
