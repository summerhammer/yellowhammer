import Config
import Domain
@testable import LinearAdapter
import Foundation
import Synchronization
import Testing

/// A minimal stand-in for `LinearAdapterTests`' own stub transport: plays back one scripted grant
/// response.
private final class StubTokenEndpointTransport: HTTPTransport, Sendable {
    private let requestCount = Mutex<Int>(0)

    var requestCountSoFar: Int { requestCount.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount.withLock { $0 += 1 }
        let body = Data(#"{"access_token":"access-2","refresh_token":"refresh-2","expires_in":7200}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (body, response)
    }
}

@Suite("LinearTokenPair's persisted-storage codec (P17.4, ADR-005)")
struct LinearTokenPairCodingTests {
    @Test("A pair round-trips through encoded()/init(storedJSON:) with an explicit ISO-8601 expiresAt")
    func roundTrips() throws {
        let pair = LinearTokenPair(
            accessToken: "access-1", refreshToken: "refresh-1",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let json = try pair.encoded()
        let decoded = try LinearTokenPair(storedJSON: json)

        #expect(decoded == pair)
        // ISO-8601, not Date's default numeric encoding.
        #expect(json.contains("2027-01-15T") || json.contains("2027-01-14T")) // UTC offset tolerant
        #expect(json.contains("\"access_token\":\"access-1\""))
        #expect(json.contains("\"refresh_token\":\"refresh-1\""))
    }

    @Test("Undecodable JSON throws")
    func undecodableJSONThrows() throws {
        #expect(throws: (any Error).self) {
            try LinearTokenPair(storedJSON: "not json")
        }
    }
}

@Suite("LinearInstallationTokenSource sharing one store (P17.4, ADR-005)")
struct SharedTokenStoreTests {
    private func temporaryLockPath() -> URL {
        FileManager.default.temporaryDirectory
            .appending(component: "yh-linear-lock-\(UUID().uuidString).lock", directoryHint: .notDirectory)
    }

    @Test("Two token sources sharing one store, backed by a real MachineLock, call the token endpoint exactly once")
    func concurrentRefreshCallsEndpointOnce() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let startingPair = LinearTokenPair(
            accessToken: "access-1", refreshToken: "refresh-1", expiresAt: now.addingTimeInterval(3600)
        )
        let pairBox = Mutex<LinearTokenPair?>(startingPair)
        let machineLock = MachineLock(fileURL: temporaryLockPath())
        let store = LinearTokenStore(
            read: { pairBox.withLock { $0 } },
            write: { newValue in pairBox.withLock { $0 = newValue } },
            withRefreshLock: { body in
                do {
                    try await machineLock.withLock(body)
                } catch let error as MachineLockError {
                    if case .bodyFailed(let inner) = error { throw inner }
                    throw error
                }
            }
        )
        let transport = StubTokenEndpointTransport()
        let sourceA = LinearInstallationTokenSource(store: store, transport: transport, clock: { now })
        let sourceB = LinearInstallationTokenSource(store: store, transport: transport, clock: { now })

        async let tokenA = sourceA.token()
        async let tokenB = sourceB.token()
        let (resultA, resultB) = try await (tokenA, tokenB)

        #expect(resultA == "access-2")
        #expect(resultB == "access-2")
        #expect(
            transport.requestCountSoFar == 1,
            "the second source must re-read the store under the lock, not refresh again"
        )
    }
}
