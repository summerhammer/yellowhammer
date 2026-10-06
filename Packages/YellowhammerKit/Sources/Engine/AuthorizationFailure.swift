import Domain

/// Classifies "authorization failure" (roadmap P17.5, Linear Board Connection Ruling items 5, 12, 13):
/// `BoardError.notAuthenticated` — a refused refresh, a revoked Installation, a 401 surviving one
/// retry, or no Installation at all. Never `.unreachable` (a network fault keeps the Outbox's ordinary
/// pending-and-retry rules) and never `.forbidden`/`.refused` (a permission or other refusal, not an
/// authorization one).
extension Error {
    /// Whether this error is (or wraps) `BoardError.notAuthenticated`. `DeltaReadError.boardUnavailable`
    /// is the one wrapper in this module that can carry one to where an Act's catch decides whether to
    /// halt on it; every other path (`Outbox`, `NightCardMaintenance`, the preflight identity read)
    /// already lets a `BoardError` propagate unwrapped.
    var isLinearAuthorizationFailure: Bool {
        if let boardError = self as? BoardError, case .notAuthenticated = boardError {
            return true
        }
        if let deltaReadError = self as? DeltaReadError, case .boardUnavailable(let boardError) = deltaReadError,
           case .notAuthenticated = boardError {
            return true
        }
        return false
    }
}

/// Runs a best-effort step (roadmap P17.5, item 1): every error is swallowed exactly as `try?` would,
/// *except* an authorization failure, which is rethrown so the enclosing Act halts on it instead of
/// silently continuing past a refused identity. Every other error's existing best-effort behaviour is
/// unchanged — this only narrows what "best-effort" swallows.
func bestEffort<T>(_ body: () async throws -> T) async throws -> T? {
    do {
        return try await body()
    } catch {
        if error.isLinearAuthorizationFailure { throw error }
        return nil
    }
}
