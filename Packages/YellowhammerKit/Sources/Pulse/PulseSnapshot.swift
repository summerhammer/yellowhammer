import Domain
import Foundation

// MARK: - Pulse

/// One Project's Pulse, in the ruled order: Needs you → Now → Feature → Tonight / last Night → Health.
public struct PulseSnapshot: Equatable, Sendable {
    public var needsYou: NeedsYou
    public var now: Now
    /// Strictly the in-flight Feature; nil when there is none, and the group states that absence. A landed
    /// Feature awaiting merge is never here: it is a member of `unmergedFeatures`.
    public var feature: FeatureInFlight?
    /// The Unmerged Feature Stack, "Awaiting merge". Its Bound is Config's fact, filled by `ProjectSnapshot.read`.
    public var unmergedFeatures: UnmergedFeatureStack
    /// The running Night, else the last one; nil when this Project has had no Night yet.
    public var night: NightPulse?
    /// Journal failures plus `yh doctor` flags. Nil means doctor was not read and no Journal
    /// failures were found; empty means doctor ran and raised none.
    public var health: [HealthFlag]?
    /// The Night window the Project's `[schedule]` puts next, or open now. Config's fact, never the Journal's:
    /// nil when no schedule was read for this Pulse.
    public var scheduledNight: ScheduledNight?

    public init(
        needsYou: NeedsYou,
        now: Now,
        feature: FeatureInFlight?,
        night: NightPulse?,
        health: [HealthFlag]?,
        scheduledNight: ScheduledNight? = nil,
        unmergedFeatures: UnmergedFeatureStack = .empty
    ) {
        self.scheduledNight = scheduledNight
        self.unmergedFeatures = unmergedFeatures
        self.needsYou = needsYou
        self.now = now
        self.feature = feature
        self.night = night
        self.health = health
    }
}

/// A Linear issue's way out: the identifier a person reads and the board URL the Journal recorded for
/// it. Authoring decisions can fall back to Linear's canonical issue URL from a validated recorded UUID.
public struct LinearIssueLink: Equatable, Sendable {
    /// Linear's issue identifier, e.g. `YH-142`.
    public var identifier: String
    public var url: URL

    public init(identifier: String, url: URL) {
        self.identifier = identifier
        self.url = url
    }

    /// The link a Journal's recorded `key` and `url` make: nil unless both are present and the URL
    /// parses with an `https` or `http` scheme, so nothing but a web page is ever opened.
    static func link(key: String?, url: String?) -> LinearIssueLink? {
        guard let key, !key.isEmpty, let url = webURL(url) else { return nil }
        return LinearIssueLink(identifier: key, url: url)
    }

    /// `text` as a URL when it parses and its scheme is `https` or `http`; otherwise nil.
    static func webURL(_ text: String?) -> URL? {
        guard
            let text, !text.isEmpty, let url = URL(string: text),
            let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }
}

/// Now: status, running Act, next scheduled Act, and running Attempts with a one-line status each.
public struct Now: Equatable, Sendable {
    public var status: ProjectStatus
    /// The Act held by the Journal's current unexpired lease, with its best available start time.
    public var runningAct: RunningAct?
    /// Nil from a Journal read: the next Act comes from the Config schedule, which the Journal does not hold.
    /// `LandingSnapshot.read` fills it.
    public var nextAct: ScheduledAct?
    public var attempts: [RunningAttempt]

    public init(
        status: ProjectStatus,
        nextAct: ScheduledAct?,
        attempts: [RunningAttempt],
        runningAct: RunningAct? = nil
    ) {
        self.status = status
        self.nextAct = nextAct
        self.attempts = attempts
        self.runningAct = runningAct
    }
}

/// An Act whose current Journal lease is still held.
public struct RunningAct: Equatable, Sendable {
    public var act: Act
    public var startedAt: Date

    public init(act: Act, startedAt: Date) {
        self.act = act
        self.startedAt = startedAt
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
    /// The running Card's Linear issue id, as the Journal records it.
    public var cardID: String
    /// The running Card's readable identifier (e.g. `ENG-123`), recorded for display.
    public var cardIDForDisplay: String?
    public var workCardTitle: String
    public var repo: String
    /// The route `(cli, model, effort)`, rendered as `Route.description` renders it.
    public var route: String
    public var startedAt: Date
    /// 1-based; a review asking for changes starts a new Round.
    public var round: Int
    /// Nil from a Journal read: no Journal column holds a one-line status.
    public var status: String?
    /// The running Card's Linear issue; nil until the Delta Read has recorded its identifier and URL.
    public var cardLink: LinearIssueLink?

    public init(
        id: String,
        cardID: String,
        cardIDForDisplay: String? = nil,
        workCardTitle: String,
        repo: String,
        route: String,
        startedAt: Date,
        round: Int,
        status: String?,
        cardLink: LinearIssueLink? = nil
    ) {
        self.id = id
        self.cardID = cardID
        self.cardIDForDisplay = cardIDForDisplay
        self.workCardTitle = workCardTitle
        self.repo = repo
        self.route = route
        self.startedAt = startedAt
        self.round = round
        self.status = status
        self.cardLink = cardLink
    }

    public init(
        id: String,
        cardID: String,
        workCardTitle: String,
        repo: String,
        route: String,
        startedAt: Date,
        round: Int,
        status: String?,
        cardLink: LinearIssueLink? = nil
    ) {
        self.init(
            id: id,
            cardID: cardID,
            cardIDForDisplay: nil,
            workCardTitle: workCardTitle,
            repo: repo,
            route: route,
            startedAt: startedAt,
            round: round,
            status: status,
            cardLink: cardLink
        )
    }
}

/// Feature: the in-flight Feature, its `rollup_state`, and its Repo Lanes.
public struct FeatureInFlight: Equatable, Sendable {
    /// The Feature Issue's Linear issue id, as the Journal records it.
    public let id: String
    /// The Feature Issue's readable identifier (e.g. `ENG-10`), recorded for display.
    public var issueIDForDisplay: String?
    /// Nil from a Journal read: the Feature Issue's title lives in Linear.
    public var title: String?
    /// The Journal's own state for the Feature (`selected`, `returned`, `closed`), not Linear's workflow state.
    public var state: String?
    /// The Roll-up word (``RollUpLattice``) over the Feature's Cards, Verification and merged fraction, read
    /// from the Journal. Nil when every Card is Shelved.
    public var rollupState: RollUpState?
    /// The clause verdicts of the Cycle's recorded Verification; nil until the land Act has verified it.
    public var verification: VerificationCounts?
    public var lanes: [RepoLaneSnapshot]
    /// The Feature Issue's Linear issue; nil until the Delta Read has recorded its identifier and URL.
    public var link: LinearIssueLink?
    /// Per repository, the display identifier of the Feature in the Unmerged Feature Stack that this Feature's
    /// recorded base stacks on. Empty when every base is mainline.
    public var stackedOn: [String: String]

    public init(
        id: String,
        issueIDForDisplay: String? = nil,
        title: String?,
        state: String?,
        rollupState: RollUpState?,
        lanes: [RepoLaneSnapshot],
        link: LinearIssueLink? = nil,
        verification: VerificationCounts? = nil,
        stackedOn: [String: String] = [:]
    ) {
        self.id = id
        self.issueIDForDisplay = issueIDForDisplay
        self.title = title
        self.state = state
        self.rollupState = rollupState
        self.verification = verification
        self.lanes = lanes
        self.link = link
        self.stackedOn = stackedOn
    }

    public init(
        id: String,
        title: String?,
        state: String?,
        rollupState: RollUpState?,
        lanes: [RepoLaneSnapshot],
        link: LinearIssueLink? = nil
    ) {
        self.init(
            id: id,
            issueIDForDisplay: nil,
            title: title,
            state: state,
            rollupState: rollupState,
            lanes: lanes,
            link: link
        )
    }
}

public struct RepoLaneSnapshot: Identifiable, Equatable, Sendable {
    public var repo: String
    public var state: LaneState
    public var cardsDone: Int
    public var cardsTotal: Int
    /// The lane's pull request chip; nil until the land Act opens one.
    public var pullRequest: PullRequestChip?
    /// The lane's member Cards in lane order, Shelved ones left out as they are from the counts. The
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
    /// The Linear issue id, as the Journal records it.
    public let id: String
    /// The readable issue identifier (e.g. `ENG-123`), recorded for display.
    public var issueIDForDisplay: String?
    public var title: String
    public var state: CardState
    /// The Card's Linear issue; nil until the Delta Read has recorded its identifier and URL.
    public var link: LinearIssueLink?

    public init(
        id: String,
        issueIDForDisplay: String? = nil,
        title: String,
        state: CardState,
        link: LinearIssueLink? = nil
    ) {
        self.id = id
        self.issueIDForDisplay = issueIDForDisplay
        self.title = title
        self.state = state
        self.link = link
    }

    public init(id: String, title: String, state: CardState, link: LinearIssueLink? = nil) {
        self.init(id: id, issueIDForDisplay: nil, title: title, state: state, link: link)
    }
}

/// A recorded pull request as a link: its number, and its URL when one is recorded. Its last observed state is the
/// entry's, not the chip's (``AwaitingMergeRepository/pullRequestObservation``).
public struct PullRequestChip: Equatable, Sendable {
    public var number: Int
    /// The pull request's web URL, as GitHub gave it. Nil when the land Act recorded none (Code Hosting answered that
    /// a pull request already existed) and only the pull request read named its number: the chip then opens nothing.
    public var url: URL?

    public init(number: Int, url: URL?) {
        self.number = number
        self.url = url
    }
}

/// A pull request's last observed state, with the time it was observed, as the engine's pull request read recorded
/// it in the Journal (app/land-on-the-sidebar-and-pulse `#pull-request-state`; OQ190 items 17 and 18). The app never
/// reads Code Hosting, so this is as fresh as the last pass, and its time says so. Display only: it changes neither
/// U nor the gate, and it never stands in for "in mainline".
public struct PullRequestObservation: Equatable, Sendable {
    public var state: ObservedPullRequestState
    public var observedAt: Date
    /// Whether the latest read for this repository failed after `observedAt`. The state and its time stay as they
    /// were: a known state is never blanked.
    public var latestReadFailed: Bool

    public init(state: ObservedPullRequestState, observedAt: Date, latestReadFailed: Bool) {
        self.state = state
        self.observedAt = observedAt
        self.latestReadFailed = latestReadFailed
    }
}

extension ObservedPullRequestState {
    /// The spec's words for the state: `open`, `merged`, `closed without merge`. Never the Journal's literal.
    public var words: String {
        switch self {
        case .open: "open"
        case .merged: "merged"
        case .closedWithoutMerge: "closed without merge"
        }
    }
}
