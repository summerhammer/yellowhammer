import Foundation
import Synchronization

/// One attempt to refresh the App Installation's token pair, as the board adapter saw it. A Port-neutral
/// value (ADR-001): it carries dates and plain strings only, never a token — every string in it has
/// already been scrubbed of the secrets the adapter holds.
public struct AppInstallationTokenRefresh: Equatable, Sendable {
    /// What made the adapter refresh.
    public enum Trigger: String, Equatable, Sendable {
        /// The scheduled path: the stored pair had less than the refresh window left.
        case nearExpiry = "near-expiry"
        /// The forced path: the board rejected the access token, and the stored pair had not moved on.
        case accessTokenRejected = "access-token-rejected"
    }

    /// A non-2xx HTTP answer to the refresh.
    public struct Refusal: Equatable, Sendable {
        /// The HTTP status of the answer.
        public let status: Int
        /// The board's opaque error code, when its body carried one.
        public let code: String?
        /// The board's own description, when its body carried one.
        public let description: String?
        /// The scrubbed message the Act reports.
        public let message: String

        public init(status: Int, code: String?, description: String?, message: String) {
            self.status = status
            self.code = code
            self.description = description
            self.message = message
        }
    }

    public enum Outcome: Equatable, Sendable {
        case refreshed(expiresAt: Date)
        /// The board answered with a non-2xx HTTP status.
        case refused(Refusal)
        /// There was no HTTP response at all (a transport failure); the scrubbed message.
        case unreachable(message: String)
        /// The board answered 2xx, but the new pair could not be decoded, or decoded but could not be
        /// written to the store. The most dangerous outcome: the board has already rotated the refresh
        /// token, so the stored one is revoked shortly after (about 30 minutes, L5 probe) and the
        /// Installation is effectively lost. It must never read as a refusal. The scrubbed message.
        case notStored(message: String)
    }

    public let attemptedAt: Date
    public let trigger: Trigger
    /// The stored pair's `expiresAt` before the attempt.
    public let previousExpiresAt: Date
    public let outcome: Outcome

    public init(attemptedAt: Date, trigger: Trigger, previousExpiresAt: Date, outcome: Outcome) {
        self.attemptedAt = attemptedAt
        self.trigger = trigger
        self.previousExpiresAt = previousExpiresAt
        self.outcome = outcome
    }
}

/// Collects the refresh attempts an Act's board makes, for the Engine to drain into the Journal. Each
/// record is handed out exactly once.
public final class AppInstallationTokenRefreshLog: Sendable {
    private let records = Mutex<[AppInstallationTokenRefresh]>([])

    public init() { }

    public func record(_ refresh: AppInstallationTokenRefresh) {
        records.withLock { $0.append(refresh) }
    }

    /// Everything recorded since the last drain, in order.
    public func drain() -> [AppInstallationTokenRefresh] {
        records.withLock { current in
            defer { current = [] }
            return current
        }
    }
}
