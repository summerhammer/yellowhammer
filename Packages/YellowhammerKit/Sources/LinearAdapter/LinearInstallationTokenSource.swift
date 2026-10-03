import Domain
import Foundation
import Synchronization

/// Obtains and refreshes the Installation's access token from a durable ``LinearTokenStore`` (P17.3,
/// ADR-005). Refreshing happens inside `store.withRefreshLock`, a machine-wide critical section
/// (P17.4: an flock), because Linear rotates the refresh token on every use: two Engine invocations
/// racing to refresh the same one would strand the loser's copy.
///
/// The stored pair, not an in-memory cache alone, is the source of truth: another process may have
/// refreshed since this actor last read it, so every refresh path re-reads the store first.
actor LinearInstallationTokenSource {
    /// Refresh once less than this much time remains before `expiresAt` — comfortably inside Linear's
    /// token lifetime, so an Act in progress never straddles an expiry mid-run.
    static let refreshWindow: TimeInterval = 2 * 60 * 60

    private let clientID: String
    private let store: LinearTokenStore
    private let transport: any HTTPTransport
    private let clock: @Sendable () -> Date
    private let refreshLog: AppInstallationTokenRefreshLog?
    private var cached: LinearTokenPair?

    init(
        clientID: String = LinearAppInstallation.clientID,
        store: LinearTokenStore,
        transport: any HTTPTransport,
        clock: @escaping @Sendable () -> Date = { Date() },
        refreshLog: AppInstallationTokenRefreshLog? = nil
    ) {
        self.refreshLog = refreshLog
        self.clientID = clientID
        self.store = store
        self.transport = transport
        self.clock = clock
    }

    func token() async throws(BoardError) -> String {
        if let cached, cached.expiresAt.timeIntervalSince(clock()) >= Self.refreshWindow {
            return cached.accessToken
        }
        return try await withRefreshLock { try await self.refreshedToken() }
    }

    /// The 401 path (`LinearAdapter.send`'s one retry): another process may have already refreshed —
    /// use its result without a refresh of our own when the store's access token has moved on;
    /// otherwise refresh regardless of how much time remains, since the rejected token proved stale.
    func recoverFromUnauthorized(rejected: String) async throws(BoardError) -> String {
        try await withRefreshLock { try await self.forceRefreshed(rejected: rejected) }
    }

    /// `clientID` is public, not a secret — Yellowhammer's one registered app id — so it is never
    /// scrubbed.
    var secrets: [String] {
        cached.map { [$0.accessToken, $0.refreshToken] } ?? []
    }

    private func refreshedToken() async throws(BoardError) -> String {
        let pair = try readPair()
        if pair.expiresAt.timeIntervalSince(clock()) >= Self.refreshWindow {
            cached = pair
            return pair.accessToken
        }
        return try await refreshAndStore(pair, trigger: .nearExpiry)
    }

    private func forceRefreshed(rejected: String) async throws(BoardError) -> String {
        let pair = try readPair()
        if pair.accessToken != rejected {
            cached = pair
            return pair.accessToken
        }
        return try await refreshAndStore(pair, trigger: .accessTokenRejected)
    }

    private func refreshAndStore(
        _ pair: LinearTokenPair, trigger: AppInstallationTokenRefresh.Trigger
    ) async throws(BoardError) -> String {
        let attemptedAt = clock()
        func record(_ outcome: AppInstallationTokenRefresh.Outcome) {
            refreshLog?.record(AppInstallationTokenRefresh(
                attemptedAt: attemptedAt, trigger: trigger, previousExpiresAt: pair.expiresAt, outcome: outcome
            ))
        }
        let refreshed: LinearTokenPair
        do throws(RefreshFailure) {
            refreshed = try await performRefresh(replacing: pair)
        } catch {
            record(error.outcome)
            throw error.boardError
        }
        do throws(BoardError) {
            try writePair(refreshed)
        } catch {
            // Linear rotated the pair but it could not be stored; the message is already scrubbed.
            record(.notStored(message: String(describing: error)))
            throw error
        }
        record(.refreshed(expiresAt: refreshed.expiresAt))
        cached = refreshed
        return refreshed.accessToken
    }

    private func readPair() throws(BoardError) -> LinearTokenPair {
        let pair: LinearTokenPair?
        do {
            pair = try store.read()
        } catch is DecodingError {
            // Not a token pair at all — most likely the withdrawn client-credentials setup left a
            // plain secret under the same reference. That is "not installed", never a network fault.
            throw .notAuthenticated(
                "the stored Linear credential is not an Installation token pair; " +
                    "re-run the Linear step of yh setup"
            )
        } catch {
            throw .unreachable("could not read Yellowhammer's stored Linear tokens: \(error)")
        }
        guard let pair else {
            throw .notAuthenticated(
                "Yellowhammer is not installed in a Linear workspace; re-run the Linear step of yh setup"
            )
        }
        return pair
    }

    private func writePair(_ pair: LinearTokenPair) throws(BoardError) {
        do {
            try store.write(pair)
        } catch {
            throw .unreachable("could not store Linear's refreshed tokens: \(error)")
        }
    }

    /// A refresh that did not yield a stored pair: the error the Act reports, and the outcome the
    /// Journal records (never `.refreshed`).
    private struct RefreshFailure: Error {
        let boardError: BoardError
        let outcome: AppInstallationTokenRefresh.Outcome

        static func unreachable(_ boardError: BoardError) -> RefreshFailure {
            RefreshFailure(boardError: boardError, outcome: .unreachable(message: String(describing: boardError)))
        }

        static func refused(
            _ boardError: BoardError, status: Int, code: String?, description: String?
        ) -> RefreshFailure {
            RefreshFailure(boardError: boardError, outcome: .refused(.init(
                status: status, code: code, description: description, message: String(describing: boardError)
            )))
        }

        /// Linear answered 2xx but its body was not a usable token pair.
        static func notStored(_ boardError: BoardError) -> RefreshFailure {
            RefreshFailure(boardError: boardError, outcome: .notStored(message: String(describing: boardError)))
        }
    }

    private func performRefresh(replacing pair: LinearTokenPair) async throws(RefreshFailure) -> LinearTokenPair {
        var request = URLRequest(url: LinearAppInstallation.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(LinearAppInstallation.formBody([
            ("grant_type", "refresh_token"),
            ("refresh_token", pair.refreshToken),
            ("client_id", clientID)
        ]).utf8)

        let failure = LinearFailure(secrets: secrets + [pair.accessToken, pair.refreshToken])
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw .unreachable(failure.transport(error))
        }
        guard (200..<300).contains(response.statusCode) else {
            let detail = failure.refusalDetail(data)
            throw .refused(
                failure.installationTokenRefused(data, response),
                status: response.statusCode, code: detail.code, description: detail.description
            )
        }
        do {
            return try LinearAppInstallation.decodeTokenPair(data, clock: clock, failure: failure)
        } catch {
            throw .notStored(error)
        }
    }

    /// Runs `body` inside `store.withRefreshLock`, translating whatever it throws back into
    /// `BoardError` — `withRefreshLock`'s own closure type is a plain (untyped) throw.
    private func withRefreshLock(
        _ body: @escaping @Sendable () async throws -> String
    ) async throws(BoardError) -> String {
        let box = Mutex<String?>(nil)
        let caught = Mutex<(any Error)?>(nil)
        do {
            try await store.withRefreshLock {
                do {
                    let value = try await body()
                    box.withLock { $0 = value }
                } catch {
                    caught.withLock { $0 = error }
                }
            }
        } catch {
            caught.withLock { $0 = error }
        }
        if let error = caught.withLock({ $0 }) {
            if let boardError = error as? BoardError {
                throw boardError
            }
            throw .unreachable("Linear token refresh lock failed: \(error)")
        }
        guard let value = box.withLock({ $0 }) else {
            throw .unreachable("Linear token refresh produced no token")
        }
        return value
    }
}
