import Domain
import Foundation

// MARK: - Night Pulse

/// Tonight / last Night: `verdict_line`, `cards_by_disposition` counts, and Night state.
public struct NightPulse: Equatable, Sendable {
    public var state: NightPulseState
    public var startedAt: Date
    /// A factual failure count from the Journal, otherwise nil; the full Night Summary lives in Engine.
    public var verdictLine: String?
    /// Cards counted by disposition, in display order; zero counts are omitted.
    public var cardsByDisposition: [DispositionCount]
    /// Explains zero touched Cards using the immutable opening observation and recorded failures.
    public var cardsAbsence: String
    /// The Night Card's Linear issue; nil until the Delta Read has recorded its identifier and URL.
    public var nightCard: LinearIssueLink?

    public init(
        state: NightPulseState,
        startedAt: Date,
        verdictLine: String?,
        cardsByDisposition: [DispositionCount],
        cardsAbsence: String = "No Cards touched",
        nightCard: LinearIssueLink? = nil
    ) {
        self.state = state
        self.startedAt = startedAt
        self.verdictLine = verdictLine
        self.cardsByDisposition = cardsByDisposition
        self.cardsAbsence = cardsAbsence
        self.nightCard = nightCard
    }
}

public enum NightPulseState: String, CaseIterable, Sendable {
    case running
    case done
    /// The Journal read never produces this: no starved record exists in the Journal.
    case starved
}

public struct DispositionCount: Identifiable, Equatable, Sendable {
    public var disposition: CardState
    public var count: Int

    public var id: CardState { disposition }

    public init(disposition: CardState, count: Int) {
        self.disposition = disposition
        self.count = count
    }
}

// MARK: - Health Flags

/// One doctor finding or aggregated Journal failure the Health group shows.
public struct HealthFlag: Identifiable, Equatable, Sendable {
    public var kind: HealthFlagKind
    public var detail: String
    public var occurrenceCount: Int
    public var lastOccurredAt: Date?
    /// When a later successful run cleared the most recent failure of this detail in the same Night.
    public var recoveredAt: Date?
    /// Undelivered Board write metadata. Set only on `.undeliveredBoardWrites`.
    public var pendingWriteCount: Int
    public var failedWriteCount: Int
    public var oldestUndeliveredAt: Date?
    public var lastError: String?

    /// A flag is its kind and detail; repeated Journal failures update its count and time.
    public var id: String { "\(kind.rawValue): \(detail)" }

    public init(
        kind: HealthFlagKind, detail: String, occurrenceCount: Int = 1, lastOccurredAt: Date? = nil,
        recoveredAt: Date? = nil, pendingWriteCount: Int = 0, failedWriteCount: Int = 0,
        oldestUndeliveredAt: Date? = nil, lastError: String? = nil
    ) {
        self.kind = kind
        self.detail = detail
        self.occurrenceCount = occurrenceCount
        self.lastOccurredAt = lastOccurredAt
        self.recoveredAt = recoveredAt
        self.pendingWriteCount = pendingWriteCount
        self.failedWriteCount = failedWriteCount
        self.oldestUndeliveredAt = oldestUndeliveredAt
        self.lastError = lastError
    }

    /// Settings destination for doctor findings. Journal failures are read-only Health rows.
    public var destination: PulseDestination {
        switch kind {
        case .staleOperatorIdentity, .appInstallationRevoked: .linearWorkspaces
        case .codeHostingConnectionRefused: .codeHosting
        case .probeFailure, .actFailure, .undeliveredBoardWrites: .settings
        }
    }
}

public enum HealthFlagKind: String, CaseIterable, Sendable {
    case staleOperatorIdentity = "stale Operator identity"
    case appInstallationRevoked = "Board Connection revoked"
    case codeHostingConnectionRefused = "Code Hosting Connection refused"
    case probeFailure = "probe failure"
    case actFailure = "Act failure"
    case undeliveredBoardWrites = "undelivered Board writes"
}
