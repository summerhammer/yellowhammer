import Domain
import Foundation

// MARK: - Night Pulse

/// Tonight / last Night: `verdict_line`, `cards_by_disposition` counts, and Night state.
public struct NightPulse: Equatable, Sendable {
    /// The Night's row id in its own Project's Journal; the Inspector's Night account is found by it.
    public var id: Int64
    public var state: NightPulseState
    public var startedAt: Date
    /// A Journal fact, never the engine's `verdict_line`: this Night's returned (or fully verified) Feature, then the
    /// failed Act run count, joined by " · "; nil when neither applies. The full Night Summary lives in Engine.
    public var verdictLine: String?
    /// Cards counted by disposition, in display order; zero counts are omitted.
    public var cardsByDisposition: [DispositionCount]
    /// Explains zero touched Cards using the immutable opening observation and recorded failures.
    public var cardsAbsence: String
    /// The Night Card's Linear issue; nil until the Delta Read has recorded its identifier and URL.
    public var nightCard: LinearIssueLink?
    /// The headline of the Night's first Act failure; the Sidebar's failure mark. Nil when none failed.
    public var firstFailureHeadline: String?
    /// The Night's Act failures in Journal order, consecutive runs failing for the same reason folded into one.
    /// Recovered ones are kept, so Tonight and Health count the same runs; Tonight lists only the others.
    public var failureNotices: [FailureNotice]

    public init(
        id: Int64,
        state: NightPulseState,
        startedAt: Date,
        verdictLine: String?,
        cardsByDisposition: [DispositionCount],
        cardsAbsence: String = "No Cards touched",
        nightCard: LinearIssueLink? = nil,
        firstFailureHeadline: String? = nil,
        failureNotices: [FailureNotice] = []
    ) {
        self.id = id
        self.state = state
        self.startedAt = startedAt
        self.verdictLine = verdictLine
        self.cardsByDisposition = cardsByDisposition
        self.cardsAbsence = cardsAbsence
        self.nightCard = nightCard
        self.firstFailureHeadline = firstFailureHeadline
        self.failureNotices = failureNotices
    }
}

/// One Failure Notice: consecutive Act runs of a Night that failed for the same recorded reason
/// (morning-report/disclose-a-failure#one-notice-per-run).
public struct FailureNotice: Identifiable, Equatable, Sendable {
    /// `Authoring “X” failed: over the description budget`: the failure's headline, which names its cause class.
    public var headline: String
    /// The runs folded into this notice.
    public var count: Int
    /// When the notice's first failure, and its last, were recorded.
    public var firstOccurredAt: Date
    public var lastOccurredAt: Date
    /// The Journal event the notice starts at.
    public var firstEventID: Int64
    /// Whether a later run got past this notice's cause, by Health's recovery rule.
    public var isRecovered: Bool

    public var id: Int64 { firstEventID }

    public init(
        headline: String, count: Int = 1, firstOccurredAt: Date, lastOccurredAt: Date, firstEventID: Int64,
        isRecovered: Bool = false
    ) {
        self.headline = headline
        self.count = count
        self.firstOccurredAt = firstOccurredAt
        self.lastOccurredAt = lastOccurredAt
        self.firstEventID = firstEventID
        self.isRecovered = isRecovered
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
    /// The class of an `.actFailure`; nil for every other kind.
    public var cause: ActFailureCause?
    /// Where the Operator fixes the failure, when the Journal knows one.
    public var fixLink: PulseDestination?
    /// What to do first, when the cause has a known answer.
    public var nextAction: String?

    /// A flag is its kind and detail; repeated Journal failures update its count and time.
    public var id: String { "\(kind.rawValue): \(detail)" }

    public init(
        kind: HealthFlagKind, detail: String, occurrenceCount: Int = 1, lastOccurredAt: Date? = nil,
        recoveredAt: Date? = nil, pendingWriteCount: Int = 0, failedWriteCount: Int = 0,
        oldestUndeliveredAt: Date? = nil, lastError: String? = nil,
        cause: ActFailureCause? = nil, fixLink: PulseDestination? = nil, nextAction: String? = nil
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
        self.cause = cause
        self.fixLink = fixLink
        self.nextAction = nextAction
    }

    /// Board repair is offered only for current provisioning failures, including the Act's recorded refusal.
    public var canRepairBoard: Bool {
        recoveredAt == nil && (kind == .boardProvisioningFailure
            || (kind == .actFailure
                && (cause == .boardScopeUnresolved
                    || detail.contains("The Project's board scope is unresolved, so this Act did no work."))))
    }

    /// Settings destination for doctor findings. An Act failure opens its own `fixLink` instead.
    public var destination: PulseDestination {
        switch kind {
        case .staleOperatorIdentity, .appInstallationRevoked, .boardProvisioningFailure: .linearWorkspaces
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
    case boardProvisioningFailure = "board provisioning failure"
    case actFailure = "Act failure"
    case undeliveredBoardWrites = "undelivered Board writes"
}
