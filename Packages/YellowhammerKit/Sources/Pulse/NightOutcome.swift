import Domain
import Foundation
import Journal

/// How often one fact occurred in a Night, and when: the first and last occurrence's time and the first one's
/// Journal event id (the order the Pulse puts problems in).
public struct Occurrence: Equatable, Sendable {
    public var count: Int
    public var firstAt: Date
    public var lastAt: Date
    public var firstEventID: Int64

    init(_ record: JournalEventRecord, count: Int = 1) {
        self.count = count
        firstAt = record.occurredAt
        lastAt = record.occurredAt
        firstEventID = record.id
    }

    mutating func add(_ record: JournalEventRecord, count: Int = 1) {
        self.count += count
        lastAt = record.occurredAt
    }
}

/// What a Night's own events say happened, folded from them alone: the Pulse's account of a Night that shipped
/// nothing, however quietly it ended. A pure value: the initializer reads no Journal, so a test can call it directly.
///
/// An Attempt failure that a later Attempt on the same Card recovered is not a Night-level notice
/// (morning-report/disclose-a-failure): a Card whose LAST `attemptEnded` in the Night is `success` contributes no
/// Attempt, Check, Route or failure-cause fact. Usage limits are per CLI, not per Card, so they are always counted,
/// and they are deferrals, not failures. The notes (unread trailers, unattributed leftovers, over-budget Managed
/// Blocks, swept Card Leases) are not Attempt failures and are not dropped by a Card's recovery.
public struct NightOutcome: Equatable, Sendable {
    /// One unrecovered Card's problem: its display identifier and how often it happened.
    public struct CardProblem: Equatable, Sendable {
        public var cardName: String
        public var occurrence: Occurrence
    }

    /// One CLI's usage limit refusals. `until` is the latest retry time recorded; `resetHint` the latest hint.
    public struct UsageLimit: Equatable, Sendable {
        public var cli: String
        public var until: Date
        public var resetHint: String?
        public var occurrence: Occurrence
    }

    /// One Route an unrecovered Card's Attempts excluded. `reason` is the first ending that excluded it.
    public struct ExcludedRoute: Equatable, Sendable {
        public var route: String
        public var reason: String
        public var cardNames: [String]
        public var occurrence: Occurrence
    }

    /// One failure cause that more than one Night has met, on an unrecovered Card.
    public struct RecurringCause: Equatable, Sendable {
        public var cardName: String
        public var cause: String
        public var recurrenceCount: Int
        public var occurrence: Occurrence
    }

    /// A kind of finding with no Card of its own: how often, and what it named (Cards, commands or Issues).
    public struct Note: Equatable, Sendable {
        public var details: [String]
        public var occurrence: Occurrence
    }

    /// Distinct Cards with an Attempt that ended this Night, and the Attempts that ended.
    public internal(set) var cardsWorked = 0
    public internal(set) var attemptsEnded = 0
    /// Whether the Night delivered work: a Cycle landed, a pull request opened, or a Card reached Done. A Card
    /// reaching Done counts so that a Feature spanning Nights, whose pull request opens on a later Night, does not
    /// read as a failed Night.
    public internal(set) var deliveredWork = false
    public internal(set) var roundsExhausted: [CardProblem] = []
    /// Outcome "hard failure", which covers timeouts and contract violations.
    public internal(set) var hardFailures: [CardProblem] = []
    /// Unrecovered Cards whose last Check of the Night failed.
    public internal(set) var redChecks: [CardProblem] = []
    public internal(set) var usageLimits: [UsageLimit] = []
    public internal(set) var excludedRoutes: [ExcludedRoute] = []
    public internal(set) var recurringCauses: [RecurringCause] = []
    public internal(set) var unreadTrailers: Note?
    /// Only processes left running that no run could be blamed for: swept ones are the system working.
    public internal(set) var unattributedLeftovers: Note?
    public internal(set) var overBudgetBlocks: Note?
    /// `occurrence.count` is the total of Cards reclaimed.
    public internal(set) var sweptCardLeases: Note?

    /// `events` are the Night's own, in Journal order. `cardNames` maps a Card's row id to its display identifier;
    /// `issueNames` maps an issue id to one (for Managed Blocks); `attemptRoutes` maps an Attempt's id to its Route's
    /// description (for a reclaimed Card's Route). Anything unnamed falls back to the id the event carries.
    public init(
        events: [JournalEventRecord],
        cardNames: [Int64: String] = [:],
        issueNames: [String: String] = [:],
        attemptRoutes: [Int64: String] = [:]
    ) {
        var fold = Fold(
            names: NightOutcomeNames(cards: cardNames, issues: issueNames, attemptRoutes: attemptRoutes),
            recovered: Fold.recoveredCards(events)
        )
        for record in events { fold.add(record) }
        self = fold.finish()
    }

    /// The Card row ids the events name, so a caller can look their display identifiers up once.
    public static func referencedCardIDs(_ events: [JournalEventRecord]) -> Set<Int64> {
        var ids: Set<Int64> = []
        for record in events {
            switch record.event {
            case .attemptEnded(let cardID, _, _, _, _, _), .failureCauseRecorded(let cardID, _, _, _, _),
                .cardCommitTrailersUnread(let cardID, _, _, _, _), .cardReclaimed(let cardID, _, _, _, _, _):
                ids.insert(cardID)
            case .checkRan(let payload): ids.insert(payload.cardID)
            case .expiredCardLeasesSwept(_, let reclaimed): ids.formUnion(reclaimed)
            default: break
            }
        }
        return ids
    }

    /// The issue ids a Managed Block over budget names.
    public static func referencedIssueIDs(_ events: [JournalEventRecord]) -> Set<String> {
        var ids: Set<String> = []
        for record in events {
            if case .managedBlockOverBudget(let issueID, _, _) = record.event { ids.insert(issueID) }
        }
        return ids
    }

    /// The Attempt ids of reclaimed Cards that excluded their Route, whose Route the events do not name.
    public static func reclaimedAttemptIDs(_ events: [JournalEventRecord]) -> [(cardID: Int64, attemptID: Int64)] {
        events.compactMap { record in
            guard case .cardReclaimed(let cardID, _, _, .some(let attemptID), _, true) = record.event else {
                return nil
            }
            return (cardID, attemptID)
        }
    }
}
