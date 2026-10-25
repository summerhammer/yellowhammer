import Domain
import Foundation

// MARK: - Night account

/// The Inspector's Night account: the Journal events of one Night, grouped by Act run, in plain words,
/// beside the Inspector's Card account (OQ158 ruling item 14).
///
/// Plain values, like the rest of the landing screen's view state. It is read-only and holds no
/// decision: whatever it surfaces is acted on in Linear.
///
/// Only Journal events are here, never agent output (OQ158 ruling item 16): no Check output, no
/// model-authored reasoning, question, reply or requested change, no process output. What an entry says
/// comes from what the engine itself recorded — identifiers, repos, routes, states, counts and reasons.
public struct NightAccount: Identifiable, Equatable, Sendable {
    /// The Night's row id in its own Project's Journal.
    public let id: Int64
    /// The Night's `NightStart` as written, `YYYY-MM-DD`.
    public var nightStart: String
    /// Whether the Night was real or a rehearsal, as the Journal recorded it.
    public var mode: NightMode
    /// `.running` while the Night is opened, else `.done` — the rule the Pulse's Night uses.
    public var state: NightPulseState
    public var openedAt: Date
    /// Nil while the Night is open.
    public var completedAt: Date?
    /// Why the Night closed, in plain words; nil while it is open.
    public var closeReason: String?
    /// The Night Card's Linear issue; nil until the Delta Read has recorded its identifier and URL.
    public var nightCard: LinearIssueLink?
    /// Every Act run of the Night, in the order its first event was recorded. It includes the runs that stood
    /// down during the Night's span, though they never joined the Night.
    public var runs: [ActRun]
    /// The Project this Night belongs to, when known.
    public var projectID: ProjectID?

    public init(
        id: Int64,
        nightStart: String,
        mode: NightMode,
        state: NightPulseState,
        openedAt: Date,
        completedAt: Date?,
        closeReason: String?,
        nightCard: LinearIssueLink?,
        runs: [ActRun],
        projectID: ProjectID? = nil
    ) {
        self.id = id
        self.nightStart = nightStart
        self.mode = mode
        self.state = state
        self.openedAt = openedAt
        self.completedAt = completedAt
        self.closeReason = closeReason
        self.nightCard = nightCard
        self.runs = runs
        self.projectID = projectID
    }

    /// How many entries, across every run, are a problem.
    public var problemCount: Int { runs.reduce(0) { $0 + $1.problemCount } }

    /// One run of an Act in this Night: the events recorded under one run id.
    ///
    /// Events recorded with no run id are not any Act's: they share one run with the id `"unstamped"` and
    /// no Act, placed where its first event falls.
    public struct ActRun: Identifiable, Equatable, Sendable {
        /// The run id's raw value, or `"unstamped"` for the events that carry none.
        public let id: String
        /// The Act's name (`author`, `build`, `land`); nil for the unstamped group.
        public var act: String?
        /// When the run's first event was recorded.
        public var startedAt: Date
        public var outcome: RunOutcome
        /// In append order.
        public var entries: [Entry]

        public init(id: String, act: String?, startedAt: Date, outcome: RunOutcome, entries: [Entry]) {
            self.id = id
            self.act = act
            self.startedAt = startedAt
            self.outcome = outcome
            self.entries = entries
        }

        /// Whether any entry of the run is a problem.
        public var hasProblem: Bool { entries.contains { $0.isProblem } }

        /// How many entries of the run are a problem.
        public var problemCount: Int { entries.count { $0.isProblem } }
    }

    /// How a run closed, from its first closing event.
    public enum RunOutcome: Equatable, Sendable {
        case ended
        /// The Act's trigger was false and it did nothing; `reason` says why, in plain words.
        case idle(reason: String)
        /// The Act could not complete; `reason` is what it knew when it gave up.
        case incomplete(reason: String)
        /// Another run held the Project, so this one ran nothing.
        case stoodDown
        /// No closing event was recorded. Not "running": with no live run behind it, it is what a
        /// killed invocation leaves, so the account never claims the run is still going.
        case notEnded
    }

    /// One Journal event, in plain words.
    public struct Entry: Identifiable, Equatable, Sendable {
        /// The event's row id in the Journal.
        public let id: Int64
        public var occurredAt: Date
        public var headline: String
        public var detail: String?
        public var isProblem: Bool
        /// The Act whose log the app can point to: set only on a problem entry that records an Act
        /// (morning-report/disclose-a-failure#log-path); nil on every running or successful entry.
        public var failedAct: Act?
        /// The dispatch prompt record id, when this entry can view its prompt.
        public var promptDispatchID: String?
        /// Whether this entry offers "View Prompt".
        public var offersPrompt: Bool

        public init(
            id: Int64, occurredAt: Date, headline: String, detail: String? = nil, isProblem: Bool = false,
            failedAct: Act? = nil, promptDispatchID: String? = nil, offersPrompt: Bool = false
        ) {
            self.id = id
            self.occurredAt = occurredAt
            self.headline = headline
            self.detail = detail
            self.isProblem = isProblem
            self.failedAct = failedAct
            self.promptDispatchID = promptDispatchID
            self.offersPrompt = offersPrompt
        }
    }
}

/// What reading one Night's account found.
public enum NightAccountRead: Equatable, Sendable {
    case account(NightAccount)
    /// The Journal records no Night with this id.
    case noSuchNight
    /// The Project has no Journal: no Act of it has run.
    case journalMissing
    /// The Journal exists but could not be read, in the Journal's own words.
    case journalFailure(String)
}
