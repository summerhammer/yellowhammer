import Domain
import Foundation

// MARK: - Pulse

/// One Project's Pulse, in the ruled order: Needs you → Now → Feature → Tonight / last Night → Health.
public struct PulseSnapshot: Equatable, Sendable {
    public var needsYou: NeedsYou
    public var now: Now
    /// The in-flight Feature; nil when there is none, and the group states that absence.
    public var feature: FeatureInFlight?
    /// The running Night, else the last one; nil when this Project has had no Night yet.
    public var night: NightPulse?
    /// `yh doctor` flags. Nil means `yh doctor` was not read (it lives in `EngineCommand`, which the app
    /// may not link, so a Journal read never fills it); empty means doctor ran and raised none.
    public var health: [HealthFlag]?

    public init(
        needsYou: NeedsYou,
        now: Now,
        feature: FeatureInFlight?,
        night: NightPulse?,
        health: [HealthFlag]?
    ) {
        self.needsYou = needsYou
        self.now = now
        self.feature = feature
        self.night = night
        self.health = health
    }
}

/// Needs you: the Project's decision Cards, Blocked and Waiting on You alike.
public struct NeedsYou: Equatable, Sendable {
    public var cards: [DecisionCard]

    public init(cards: [DecisionCard]) {
        self.cards = cards
    }

    public var waitingOnYouCount: Int {
        cards.count { $0.state == .waitingOnYou }
    }

    /// Blocked Cards counted by Block Reason, most frequent first.
    public var blockReasonCounts: [(reason: BlockReason, count: Int)] {
        let reasons = cards.compactMap(\.blockReason)
        return BlockReason.allCases
            .compactMap { reason in
                let tally = reasons.count { $0 == reason }
                return tally > 0 ? (reason: reason, count: tally) : nil
            }
            .sorted { $0.count > $1.count }
    }
}

/// A Card that needs a decision, opened in one hop into the Inspector.
public struct DecisionCard: Identifiable, Equatable, Sendable {
    /// The Linear issue identifier, e.g. `YH-142`.
    public let id: String
    public var title: String
    /// `.blocked` or `.waitingOnYou`.
    public var state: CardState
    /// Set only when `state` is `.blocked`.
    public var blockReason: BlockReason?
    public var repo: String

    public init(id: String, title: String, state: CardState, blockReason: BlockReason?, repo: String) {
        self.id = id
        self.title = title
        self.state = state
        self.blockReason = blockReason
        self.repo = repo
    }
}

/// Now: status, next scheduled Act, and running Attempts with a one-line status each.
public struct Now: Equatable, Sendable {
    public var status: ProjectStatus
    /// Nil from a Journal read: the next Act needs the Config schedule and `launchd`, neither of which the
    /// Journal holds.
    public var nextAct: ScheduledAct?
    public var attempts: [RunningAttempt]

    public init(status: ProjectStatus, nextAct: ScheduledAct?, attempts: [RunningAttempt]) {
        self.status = status
        self.nextAct = nextAct
        self.attempts = attempts
    }
}

public struct ScheduledAct: Equatable, Sendable {
    public var act: Act
    public var at: Date

    public init(act: Act, at: Date) {
        self.act = act
        self.at = at
    }
}

/// A running Attempt. `status` is one line of status, never output from the agent CLI.
public struct RunningAttempt: Identifiable, Equatable, Sendable {
    public let id: String
    public var cardID: String
    public var cardTitle: String
    public var repo: String
    /// The route `(cli, model, effort)`, rendered as `Route.description` renders it.
    public var route: String
    public var startedAt: Date
    /// 1-based; a review asking for changes starts a new Round.
    public var round: Int
    /// Nil from a Journal read: no Journal column holds a one-line status.
    public var status: String?

    public init(
        id: String,
        cardID: String,
        cardTitle: String,
        repo: String,
        route: String,
        startedAt: Date,
        round: Int,
        status: String?
    ) {
        self.id = id
        self.cardID = cardID
        self.cardTitle = cardTitle
        self.repo = repo
        self.route = route
        self.startedAt = startedAt
        self.round = round
        self.status = status
    }
}

/// Feature: the in-flight Feature, its `rollup_state`, and its Repo Lanes.
public struct FeatureInFlight: Equatable, Sendable {
    /// The Feature Issue's Linear identifier.
    public let id: String
    /// Nil from a Journal read: the Feature Issue's title lives in Linear.
    public var title: String?
    /// The Feature Issue's Linear workflow state. Nil from a Journal read: it lives in Linear.
    public var state: String?
    /// Nil from a Journal read: only Engine's `FeatureRollUp` computes it, and the app may not link Engine.
    public var rollupState: RollUpState?
    public var lanes: [RepoLaneSnapshot]

    public init(
        id: String,
        title: String?,
        state: String?,
        rollupState: RollUpState?,
        lanes: [RepoLaneSnapshot]
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.rollupState = rollupState
        self.lanes = lanes
    }
}

public struct RepoLaneSnapshot: Identifiable, Equatable, Sendable {
    public var repo: String
    public var state: LaneState
    public var cardsDone: Int
    public var cardsTotal: Int
    /// The lane's pull request chip; nil until the land Act opens one.
    public var pullRequest: PullRequestChip?
    /// The lane's member Cards in lane order, Cancelled ones left out as they are from the counts. The
    /// Feature and Repo detail list them.
    public var cards: [LaneCard]

    public var id: String { repo }

    public init(
        repo: String,
        state: LaneState,
        cardsDone: Int,
        cardsTotal: Int,
        pullRequest: PullRequestChip?,
        cards: [LaneCard] = []
    ) {
        self.repo = repo
        self.state = state
        self.cardsDone = cardsDone
        self.cardsTotal = cardsTotal
        self.pullRequest = pullRequest
        self.cards = cards
    }
}

/// One member Card of a Repo Lane: enough to list it in the Inspector.
public struct LaneCard: Identifiable, Equatable, Sendable {
    /// The Linear issue identifier, e.g. `YH-142`.
    public let id: String
    public var title: String
    public var state: CardState

    public init(id: String, title: String, state: CardState) {
        self.id = id
        self.title = title
        self.state = state
    }
}

public struct PullRequestChip: Equatable, Sendable {
    public var number: Int
    /// Nil from a Journal read: a pull request's state lives in GitHub.
    public var state: PullRequestState?

    public init(number: Int, state: PullRequestState?) {
        self.number = number
        self.state = state
    }
}

public enum PullRequestState: String, CaseIterable, Sendable {
    case open
    case draft
    case merged
    case closed
}

/// Tonight / last Night: `verdict_line`, `cards_by_disposition` counts, and Night state.
public struct NightPulse: Equatable, Sendable {
    public var state: NightPulseState
    public var startedAt: Date
    /// Nil from a Journal read: only Engine's `NightSummary` computes it.
    public var verdictLine: String?
    /// Cards counted by disposition, in display order; zero counts are omitted.
    public var cardsByDisposition: [DispositionCount]

    public init(
        state: NightPulseState,
        startedAt: Date,
        verdictLine: String?,
        cardsByDisposition: [DispositionCount]
    ) {
        self.state = state
        self.startedAt = startedAt
        self.verdictLine = verdictLine
        self.cardsByDisposition = cardsByDisposition
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

/// One `yh doctor` flag the Health group shows.
public struct HealthFlag: Identifiable, Equatable, Sendable {
    public var kind: HealthFlagKind
    public var detail: String

    /// A flag is its kind and its detail: two CLIs can each raise a probe failure.
    public var id: String { "\(kind.rawValue): \(detail)" }

    public init(kind: HealthFlagKind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    /// Where the flag's fix lives: the Boards pane for the two installation flags, the
    /// Project's Settings entry for a probe failure.
    public var destination: PulseDestination {
        switch kind {
        case .staleOperatorIdentity, .appInstallationRevoked: .linearWorkspaces
        case .probeFailure: .settings
        }
    }
}

public enum HealthFlagKind: String, CaseIterable, Sendable {
    case staleOperatorIdentity = "stale Operator identity"
    case appInstallationRevoked = "App Installation revoked"
    case probeFailure = "probe failure"
}
