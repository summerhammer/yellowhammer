import Domain
import Foundation
import Journal

extension PulseSnapshot {
    /// Fills one Project's Pulse from its Journal.
    ///
    /// The read is HANDED a store and never opens one, so it structurally cannot reach a sibling
    /// Project's Journal (ADR-002): every value below comes from this one store. It only reads.
    ///
    /// What the Journal cannot say stays nil: `now.nextAct`, the Feature's title/state/rollup state, a
    /// pull request's state, an Attempt's status line, the Night's verdict line and `health`.
    ///
    /// `status` is handed in: it comes from `launchd` (is the Project's Act job alive?), which the
    /// Journal cannot say, so the caller reads it and the Journal's Act Lease plays no part.
    public static func read(from journal: JournalStore, status: ProjectStatus) throws -> PulseSnapshot {
        let inFlight = try journal.inFlightFeature()
        return PulseSnapshot(
            needsYou: try needsYou(journal),
            now: try now(journal, inFlight: inFlight, status: status),
            feature: try feature(journal, inFlight: inFlight),
            night: try night(journal),
            health: nil
        )
    }

    // MARK: Needs you

    private static func needsYou(_ journal: JournalStore) throws -> NeedsYou {
        let cards = try journal.cards().compactMap { card -> DecisionCard? in
            guard card.state == .blocked || card.state == .waitingOnYou else { return nil }
            return DecisionCard(
                id: card.issueID,
                title: card.displayTitle,
                state: card.state,
                blockReason: card.state == .blocked ? card.blockReason.flatMap { BlockReason(rawValue: $0) } : nil,
                repo: card.repository,
                link: LinearIssueLink.link(key: card.issueKey, url: card.issueURL)
            )
        }
        return NeedsYou(cards: cards)
    }

    // MARK: Now

    private static func now(
        _ journal: JournalStore,
        inFlight: (feature: FeatureRecord, cycleID: Int64)?,
        status: ProjectStatus
    ) throws -> Now {
        var attempts: [RunningAttempt] = []
        if let inFlight {
            for card in try journal.cards(cycleID: inFlight.cycleID) {
                let history = try journal.attemptHistory(cardID: card.id)
                guard let open = history.openAttempt else { continue }
                attempts.append(
                    RunningAttempt(
                        id: String(open.id),
                        cardID: card.issueID,
                        cardTitle: card.displayTitle,
                        repo: card.repository,
                        route: open.route.description,
                        startedAt: open.startedAt,
                        round: round(of: open),
                        status: nil,
                        cardLink: LinearIssueLink.link(key: card.issueKey, url: card.issueURL)
                    ))
            }
        }
        return Now(status: status, nextAct: nil, attempts: attempts)
    }

    /// 1-based. Every recorded Round that asked for changes started a further Round of the same
    /// Attempt, so the current Round is one more than those; Rounds that passed (a green Check, an
    /// approving review) do not advance it.
    private static func round(of attempt: AttemptRecord) -> Int {
        1 + attempt.rounds.count { $0.requestedChanges != nil }
    }

    // MARK: Feature

    private static func feature(
        _ journal: JournalStore,
        inFlight: (feature: FeatureRecord, cycleID: Int64)?
    ) throws -> FeatureInFlight? {
        guard let inFlight else { return nil }
        let featureID = inFlight.feature.id
        let cards = try journal.cards(cycleID: inFlight.cycleID)
        let landed = try journal.landings(featureID: featureID)
        let pullRequests = try journal.pullRequests(featureID: featureID)

        var repos = try journal.touchedRepositories(featureID: featureID)
        for card in cards where !repos.contains(card.repository) {
            repos.append(card.repository)
        }
        let lanes = repos.map { repo -> RepoLaneSnapshot in
            // A Cancelled Card is out of the lane: it counts toward neither done nor total.
            let laneCards = cards.filter { $0.repository == repo && $0.state != .cancelled }
            let state: LaneState =
                if landed[repo] != nil {
                    .landed
                } else if laneCards.contains(where: { $0.state == .blocked }) {
                    .blocked
                } else if laneCards.contains(where: { $0.state == .waitingOnYou }) {
                    .waitingOnYou
                } else {
                    .running
                }
            return RepoLaneSnapshot(
                repo: repo,
                state: state,
                cardsDone: laneCards.count { $0.state == .done },
                cardsTotal: laneCards.count,
                pullRequest: pullRequests[repo].flatMap(chip),
                cards: laneCards.map { card in
                    LaneCard(
                        id: card.issueID,
                        title: card.displayTitle,
                        state: card.state,
                        link: LinearIssueLink.link(key: card.issueKey, url: card.issueURL)
                    )
                }
            )
        }
        return FeatureInFlight(
            id: inFlight.feature.issueID,
            title: nil,
            state: nil,
            rollupState: nil,
            lanes: lanes,
            link: LinearIssueLink.link(key: inFlight.feature.issueKey, url: inFlight.feature.issueURL)
        )
    }

    /// The pull request's number is the last path component of its URL; nil when there is no URL, it is
    /// not an `https` or `http` URL, or it does not end in a number.
    private static func chip(_ record: PullRequestRecord) -> PullRequestChip? {
        guard
            let text = record.url, let url = LinearIssueLink.webURL(text),
            let number = Int(text.split(separator: "/").last ?? "")
        else { return nil }
        return PullRequestChip(number: number, url: url, state: nil)
    }

    // MARK: Night

    private static func night(_ journal: JournalStore) throws -> NightPulse? {
        // `nights()` is oldest first, so the last is the most recent.
        guard let night = try journal.currentNight() ?? journal.nights().last else { return nil }
        return NightPulse(
            state: night.state == .opened ? .running : .done,
            startedAt: night.openedAt,
            verdictLine: nil,
            cardsByDisposition: try dispositions(night: night, journal: journal),
            nightCard: LinearIssueLink.link(key: night.nightCardIssueKey, url: night.nightCardIssueURL)
        )
    }

    /// The event types that make a Card "touched" this Night. This mirrors Engine's
    /// `NightSummary.touchedCardEventTypes`, reimplemented because Pulse may not import Engine.
    private static let touchedCardEventTypes: Set<JournalEventType> = [
        .attemptEnded, .checkRan, .cardRunStep, .cardStateTransitioned, .routeRetried, .cardReclaimed
    ]

    /// Cards touched this Night, counted by their current state in `CardState` case order, zero counts
    /// omitted. Engine's `NightSummary` reports only Blocked and Waiting on You over these Cards; the
    /// Pulse extends the same touched-Card set to every state (an approximation of "disposition").
    private static func dispositions(night: NightRecord, journal: JournalStore) throws -> [DispositionCount] {
        var touched: Set<Int64> = []
        let events = try journal.events().filter {
            $0.nightID == night.id && touchedCardEventTypes.contains($0.type)
        }
        for record in events {
            switch record.event {
            case .attemptEnded(let cardID, _, _, _, _, _),
                .checkRan(let cardID, _, _, _, _, _),
                .cardRunStep(let cardID, _, _, _),
                .cardStateTransitioned(let cardID, _, _, _, _, _),
                .routeRetried(let cardID, _, _, _, _),
                .cardReclaimed(let cardID, _, _, _, _, _):
                touched.insert(cardID)
            default:
                break
            }
        }
        let states = try touched.map { try journal.card(id: $0).state }
        return CardState.allCases.compactMap { state in
            let count = states.count { $0 == state }
            return count > 0 ? DispositionCount(disposition: state, count: count) : nil
        }
    }
}
