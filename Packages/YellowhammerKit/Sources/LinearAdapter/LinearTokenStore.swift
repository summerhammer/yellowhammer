import Foundation

/// The Installation's persisted token pair, read and written by whatever backs it (P17.4: the Keychain
/// plus a per-Installation flock). `read` returns nil when Yellowhammer is not installed. `withRefreshLock`
/// wraps the critical section around a read-refresh-write so two concurrent Engine invocations never
/// race to refresh the same refresh token — Linear rotates it, so a lost race would lock the loser out.
public struct LinearTokenStore: Sendable {
    public var read: @Sendable () throws -> LinearTokenPair?
    public var write: @Sendable (LinearTokenPair) throws -> Void
    public var withRefreshLock: @Sendable (@Sendable () async throws -> Void) async throws -> Void

    public init(
        read: @escaping @Sendable () throws -> LinearTokenPair?,
        write: @escaping @Sendable (LinearTokenPair) throws -> Void,
        withRefreshLock: @escaping @Sendable (@Sendable () async throws -> Void) async throws -> Void
    ) {
        self.read = read
        self.write = write
        self.withRefreshLock = withRefreshLock
    }
}
