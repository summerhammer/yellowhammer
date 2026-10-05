import Domain
import Foundation

// MARK: - Card detail

/// The Inspector's Card detail: the read-only account behind one Card, as its own Project's Journal
/// recorded it — the Card, the routes tried and excluded, and every Attempt with its Rounds and Check
/// runs, oldest first (roadmap P14.5, carried into the Inspector by P18.8).
///
/// Plain values, like the rest of the landing screen's view state. Nothing here is a triage gesture:
/// re-ready and answer are made on the Card's Linear issue, which the Inspector opens.
///
/// Only what the Journal holds is here. The Managed Block (Architectural Brief, DoD clauses), the
/// question-and-answer thread, `model_only_green`, `bound_fired` and the un-adopted elapsed-Nights
/// figure are not: the first two live on the Linear issue, and the Journal read has no column or
/// reference Night for the others.
public struct CardDetail: Identifiable, Equatable, Sendable {
    /// The Linear issue id, as the Journal records it.
    public let id: String
    /// The readable issue identifier (e.g. `ENG-123`), recorded for display.
    public var issueIDForDisplay: String?
    /// The board's title as the Journal last reconciled it, else the issue id.
    public var title: String
    public var repo: String
    /// The Card's `kind`, as authored.
    public var kind: String
    public var state: CardState
    /// Set only when `state` is `.waitingOnYou`: the Journal's `waiting_reason`, e.g. `question` or
    /// `divergence`. Shown beside the state, never as a chip.
    public var waitingReason: String?
    /// Set only when `state` is `.blocked`.
    public var blockReason: BlockReason?
    public var budgetEpoch: Int
    /// Distinct routes tried, in the order first tried, each rendered as `Route.description` renders it.
    public var routesTried: [String]
    /// The routes excluded from further Attempts, in the order excluded.
    public var excludedRoutes: [String]
    /// Every Attempt, oldest first.
    public var attempts: [Attempt]
    /// The Card's Linear issue; nil until the Delta Read has recorded its identifier and URL.
    public var link: LinearIssueLink?

    public init(
        id: String,
        issueIDForDisplay: String? = nil,
        title: String,
        repo: String,
        kind: String,
        state: CardState,
        waitingReason: String?,
        blockReason: BlockReason?,
        budgetEpoch: Int,
        routesTried: [String],
        excludedRoutes: [String],
        attempts: [Attempt],
        link: LinearIssueLink? = nil
    ) {
        self.id = id
        self.issueIDForDisplay = issueIDForDisplay
        self.title = title
        self.repo = repo
        self.kind = kind
        self.state = state
        self.waitingReason = waitingReason
        self.blockReason = blockReason
        self.budgetEpoch = budgetEpoch
        self.routesTried = routesTried
        self.excludedRoutes = excludedRoutes
        self.attempts = attempts
        self.link = link
    }

    public init(
        id: String,
        title: String,
        repo: String,
        kind: String,
        state: CardState,
        waitingReason: String?,
        blockReason: BlockReason?,
        budgetEpoch: Int,
        routesTried: [String],
        excludedRoutes: [String],
        attempts: [Attempt],
        link: LinearIssueLink? = nil
    ) {
        self.init(
            id: id,
            issueIDForDisplay: nil,
            title: title,
            repo: repo,
            kind: kind,
            state: state,
            waitingReason: waitingReason,
            blockReason: blockReason,
            budgetEpoch: budgetEpoch,
            routesTried: routesTried,
            excludedRoutes: excludedRoutes,
            attempts: attempts,
            link: link
        )
    }

    public var attemptCount: Int { attempts.count }
    public var roundCount: Int { attempts.reduce(0) { $0 + $1.rounds.count } }

    /// One dispatch of the Card to a route, with the Rounds judged over its work and the Check runs
    /// against it. An Attempt ends only on a hard failure or its outcome; a review asking for changes is
    /// a new Round of the same Attempt.
    public struct Attempt: Identifiable, Equatable, Sendable {
        public let id: String
        /// The route `(cli, model, effort)`, rendered as `Route.description` renders it.
        public var route: String
        /// How the route was selected: `entry`, `fallback:<n>` or `override`; nil when not recorded.
        public var routeSource: String?
        /// The Override pinned in triage when the Attempt started; nil when none was.
        public var overridePin: String?
        public var startedAt: Date
        /// Nil while the Attempt has not ended.
        public var endedAt: Date?
        /// The Attempt's outcome as the Journal recorded it; nil until it ends.
        public var result: String?
        public var classification: String?
        public var consumedHow: String?
        /// The preserved ref, and the commit it points at, when a reset moved the Feature Branch away.
        public var preservedRef: String?
        public var preservedCommit: String?
        /// The Repo declared `check = "none"` for this Attempt.
        public var checkDeclaredNone: Bool
        /// In ascending ordinal.
        public var rounds: [Round]
        /// In append order.
        public var checkRuns: [CheckRun]

        public init(
            id: String,
            route: String,
            routeSource: String?,
            overridePin: String?,
            startedAt: Date,
            endedAt: Date?,
            result: String?,
            classification: String?,
            consumedHow: String?,
            preservedRef: String?,
            preservedCommit: String?,
            checkDeclaredNone: Bool,
            rounds: [Round],
            checkRuns: [CheckRun]
        ) {
            self.id = id
            self.route = route
            self.routeSource = routeSource
            self.overridePin = overridePin
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.result = result
            self.classification = classification
            self.consumedHow = consumedHow
            self.preservedRef = preservedRef
            self.preservedCommit = preservedCommit
            self.checkDeclaredNone = checkDeclaredNone
            self.rounds = rounds
            self.checkRuns = checkRuns
        }
    }

    /// One judgement pass over an Attempt's work, from a Lens.
    public struct Round: Identifiable, Equatable, Sendable {
        public let id: String
        public var lens: Lens
        public var verdict: String
        /// A review's requested changes, or a failed Check's output; nil when the Round passed.
        public var requestedChanges: String?
        public var judgedCommit: String?

        public init(id: String, lens: Lens, verdict: String, requestedChanges: String?, judgedCommit: String?) {
            self.id = id
            self.lens = lens
            self.verdict = verdict
            self.requestedChanges = requestedChanges
            self.judgedCommit = judgedCommit
        }
    }

    /// One engine-run Check, as its `checkRan` event recorded it. Its output is the runner's capped tail.
    public struct CheckRun: Identifiable, Equatable, Sendable {
        public let id: String
        public var result: CheckRunResult
        public var exitStatus: Int32?
        public var output: String?
        public var occurredAt: Date

        public init(id: String, result: CheckRunResult, exitStatus: Int32?, output: String?, occurredAt: Date) {
            self.id = id
            self.result = result
            self.exitStatus = exitStatus
            self.output = output
            self.occurredAt = occurredAt
        }
    }
}

/// What reading one Card's detail found.
public enum CardDetailRead: Equatable, Sendable {
    case detail(CardDetail)
    /// The Journal records no Card with this issue id.
    case noSuchCard
    /// The Project has no Journal: no Act of it has run.
    case journalMissing
    /// The Journal exists but could not be read, in the Journal's own words.
    case journalFailure(String)
}
