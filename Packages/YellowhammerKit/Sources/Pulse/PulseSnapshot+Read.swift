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
    /// pull request's state, an Attempt's status line, and the full Night Summary.
    ///
    /// `status` is handed in as the launchd fallback. An unexpired Journal lease is the authoritative
    /// running Act when readable; launchd remains useful when the Journal is absent or unreadable.
    public static func read(
        from journal: JournalStore, status: ProjectStatus, asOf: Date = Date()
    ) throws -> PulseSnapshot {
        let inFlight = try journal.inFlightFeature()
        let leaseState = try runningAct(journal, asOf: asOf)
        let runningAct = leaseState.runningAct
        let resolvedStatus: ProjectStatus = if runningAct != nil {
            .working
        } else if leaseState.suppressFallback {
            .idle
        } else {
            status
        }
        let now = try now(journal, inFlight: inFlight, status: resolvedStatus, runningAct: runningAct)
        let selectedNight = try journal.currentNight() ?? journal.nights(mode: .real).last
        let events = try journal.pulseEvents(
            nightID: selectedNight?.id,
            unstampedFailuresSince: selectedNight?.openedAt ?? Date(timeIntervalSince1970: 0)
        )
        let failures = JournalFailures(events: events)
        let liveRunID = runningAct != nil ? try journal.currentActLease()?.runID : nil
        return PulseSnapshot(
            needsYou: try needsYou(journal),
            now: now,
            feature: try feature(
                journal, inFlight: inFlight, now: now,
                runningLanes: runningLanes(night: selectedNight, events: events, liveRunID: liveRunID)
            ),
            night: try selectedNight.map { try night($0, journal: journal, events: events) },
            health: failures.flags.isEmpty ? nil : failures.flags
        )
    }

    /// Adds doctor findings without dropping failures already read from this Project's Journal.
    public mutating func mergeDoctorHealth(_ flags: [HealthFlag]?) {
        guard let flags else { return }
        health = (health ?? []) + flags
    }

    // MARK: Needs you

    private static func needsYou(_ journal: JournalStore) throws -> NeedsYou {
        let cards = try journal.cards().compactMap { card -> DecisionCard? in
            guard card.state == .blocked || card.state == .waitingOnYou else { return nil }
            return DecisionCard(
                id: card.issueID,
                issueIDForDisplay: card.issueIDForDisplay ?? card.issueKey,
                title: card.displayTitle,
                state: card.state,
                blockReason: card.state == .blocked ? card.blockReason.flatMap { BlockReason(rawValue: $0) } : nil,
                repo: card.repository,
                link: LinearIssueLink.link(key: card.issueIDForDisplay ?? card.issueKey, url: card.issueURL)
            )
        }
        return NeedsYou(cards: cards)
    }

    // MARK: Now

    private static func now(
        _ journal: JournalStore,
        inFlight: (feature: FeatureRecord, cycleID: Int64)?,
        status: ProjectStatus,
        runningAct: RunningAct?
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
                        cardIDForDisplay: card.issueIDForDisplay ?? card.issueKey,
                        workCardTitle: card.displayTitle,
                        repo: card.repository,
                        route: open.route.description,
                        startedAt: open.startedAt,
                        round: round(of: open),
                        status: nil,
                        cardLink: LinearIssueLink.link(key: card.issueIDForDisplay ?? card.issueKey, url: card.issueURL)
                    ))
            }
        }
        return Now(status: status, nextAct: nil, attempts: attempts, runningAct: runningAct)
    }

    private static func runningAct(
        _ journal: JournalStore, asOf: Date
    ) throws -> (runningAct: RunningAct?, suppressFallback: Bool) {
        guard let lease = try journal.currentActLease() else {
            let latest = try journal.latestActLifecycleEvent()
            let finished = latest?.type == .actEnded || latest?.type == .actIncomplete
            return (nil, finished)
        }
        guard lease.isHeld(at: asOf) else { return (nil, true) }
        let lifecycle = try journal.events(
            runID: lease.runID, ofTypes: [.actStarted, .actEnded, .actIncomplete]
        )
        guard !lifecycle.contains(where: { $0.type == .actEnded || $0.type == .actIncomplete }) else {
            return (nil, true)
        }
        let startedAt = lifecycle.first(where: { $0.type == .actStarted })?.occurredAt ?? lease.claimedAt
        return (RunningAct(act: lease.act, startedAt: startedAt), true)
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
        inFlight: (feature: FeatureRecord, cycleID: Int64)?,
        now: Now,
        runningLanes: Set<String>
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
        let context = FeatureLaneContext(
            cards: cards,
            landed: landed,
            pullRequests: pullRequests,
            now: now,
            runningLanes: runningLanes
        )
        let lanes = repos.map { repo in
            repoLane(repo: repo, context: context)
        }
        return FeatureInFlight(
            id: inFlight.feature.issueID,
            issueIDForDisplay: inFlight.feature.issueIDForDisplay ?? inFlight.feature.issueKey,
            title: nil,
            state: nil,
            rollupState: nil,
            lanes: lanes,
            link: LinearIssueLink.link(
                key: inFlight.feature.issueIDForDisplay ?? inFlight.feature.issueKey,
                url: inFlight.feature.issueURL
            )
        )
    }

    private struct FeatureLaneContext {
        let cards: [CardRecord]
        let landed: [String: String]
        let pullRequests: [String: PullRequestRecord]
        let now: Now
        let runningLanes: Set<String>
    }

    private static func repoLane(
        repo: String,
        context: FeatureLaneContext
    ) -> RepoLaneSnapshot {
        // A Shelved Card is out of the lane: it counts toward neither done nor total.
        let laneCards = context.cards.filter { $0.repository == repo && $0.state != .shelved }
        let state: LaneState =
            if context.landed[repo] != nil {
                .landed
            } else if laneCards.contains(where: { $0.state == .blocked }) {
                .blocked
            } else if laneCards.contains(where: { $0.state == .waitingOnYou }) {
                .waitingOnYou
            } else if context.now.attempts.contains(where: { $0.repo == repo })
                || context.runningLanes.contains(repo) {
                .running
            } else {
                .idle
            }
        return RepoLaneSnapshot(
            repo: repo,
            state: state,
            cardsDone: laneCards.count { $0.state == .done },
            cardsTotal: laneCards.count,
            pullRequest: context.pullRequests[repo].flatMap(chip),
            cards: laneCards.map { card in
                LaneCard(
                    id: card.issueID,
                    issueIDForDisplay: card.issueIDForDisplay ?? card.issueKey,
                    title: card.displayTitle,
                    state: card.state,
                    link: LinearIssueLink.link(key: card.issueIDForDisplay ?? card.issueKey, url: card.issueURL)
                )
            }
        )
    }

    private static func runningLanes(
        night: NightRecord?, events: [JournalEventRecord], liveRunID: RunID?
    ) -> Set<String> {
        guard night?.state == .opened, let liveRunID else { return [] }
        var repos: Set<String> = []
        for record in events where record.runID == liveRunID {
            switch record.event {
            case .repoLaneStarted(let repository, _): repos.insert(repository)
            case .repoLaneEnded(let repository, _, _, _): repos.remove(repository)
            default: break
            }
        }
        return repos
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

    private static func night(
        _ night: NightRecord, journal: JournalStore, events: [JournalEventRecord]
    ) throws -> NightPulse {
        // Unstamped invocation failures belong in Health, not in a Night they never reached.
        let count = JournalFailures(events: events.filter { $0.nightID == night.id }).failedRunCount
        let opening = try journal.openingReadyState(nightID: night.id)
        let eligibility = opening == .zero ? "no eligible Cards at opening" : "opening eligibility unknown"
        let absence: String = if count > 0, opening == .nonzero {
            "No Cards touched — eligible Cards were available; Act failures recorded"
        } else if count > 0 {
            "No Cards touched — Acts failed; \(eligibility)"
        } else if opening == .zero {
            "No Cards touched — no eligible Cards at opening"
        } else {
            "No Cards touched"
        }
        return NightPulse(
            state: night.state == .opened ? .running : (count > 0 ? .halted : .done),
            startedAt: night.openedAt,
            verdictLine: count > 0 ? "\(count) Act run\(count == 1 ? "" : "s") failed — see Health" : nil,
            cardsByDisposition: try dispositions(night: night, journal: journal, events: events),
            cardsAbsence: absence,
            nightCard: LinearIssueLink.link(
                key: night.nightCardIssueIDForDisplay ?? night.nightCardIssueKey,
                url: night.nightCardIssueURL
            )
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
    private static func dispositions(night: NightRecord, journal: JournalStore, events: [JournalEventRecord]
    ) throws -> [DispositionCount] {
        var touched: Set<Int64> = []
        let events = events.filter {
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
