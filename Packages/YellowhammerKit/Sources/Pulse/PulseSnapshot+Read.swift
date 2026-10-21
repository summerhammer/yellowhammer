import Domain
import Foundation
import Journal

extension PulseSnapshot {
    /// Fills one Project's Pulse from its Journal.
    ///
    /// The read is HANDED a store and never opens one, so it structurally cannot reach a sibling
    /// Project's Journal (ADR-002): every value below comes from this one store. It only reads.
    ///
    /// What the Journal cannot say stays nil: `now.nextAct`, the Feature's title, a
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
        let failures = JournalFailures(
            events: events,
            nightCard: selectedNight.flatMap(nightCardLink)
        )
        let outboxFlags = try Self.undeliveredBoardWrites(journal)
        let liveRunID = runningAct != nil ? try journal.currentActLease()?.runID : nil
        return PulseSnapshot(
            needsYou: try needsYou(journal, inFlight: inFlight),
            now: now,
            feature: try feature(
                journal, inFlight: try inFlight ?? featureLandedTonight(journal, night: selectedNight, events: events),
                now: now,
                runningLanes: runningLanes(night: selectedNight, events: events, liveRunID: liveRunID)
            ),
            night: try selectedNight.map { try night($0, journal: journal, events: events) },
            health: (failures.flags + outboxFlags).isEmpty ? nil : failures.flags + outboxFlags
        )
    }

    /// One aggregated, read-only Health flag for Board writes that have not been delivered or aborted.
    private static func undeliveredBoardWrites(_ journal: JournalStore) throws -> [HealthFlag] {
        let entries = try journal.undeliveredOutboxEntries()
        guard !entries.isEmpty else { return [] }
        let pending = entries.count { $0.state == .pending }
        let failed = entries.count { $0.state == .failed }
        let lastError = entries.reversed().compactMap(\.lastError).first
        let oldest = entries.map(\.createdAt).min()
        return [HealthFlag(
            kind: .undeliveredBoardWrites, detail: "Linear not updated",
            occurrenceCount: entries.count, pendingWriteCount: pending, failedWriteCount: failed,
            oldestUndeliveredAt: oldest, lastError: lastError
        )]
    }

    /// Adds doctor findings without dropping failures already read from this Project's Journal.
    public mutating func mergeDoctorHealth(_ flags: [HealthFlag]?) {
        guard let flags else { return }
        health = (health ?? []) + flags
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

    /// With no Feature in flight, the latest Feature whose Cycle landed during `night` — the slot is free again
    /// the moment the land Act archives the Cycle (a periodic author firing may select the next Feature within
    /// minutes), and without this the Feature group would be empty right after a mid-Night landing. Nil when
    /// no Cycle landed in this Night. The Pulse shows no other member of the Unmerged Feature Stack.
    private static func featureLandedTonight(
        _ journal: JournalStore, night: NightRecord?, events: [JournalEventRecord]
    ) throws -> (feature: FeatureRecord, cycleID: Int64)? {
        guard let night else { return nil }
        let landed = events.reversed().first { $0.nightID == night.id && $0.type == .cycleLanded }
        guard let landed, case .cycleLanded(let cycleID) = landed.event,
            let feature = try journal.feature(cycleID: cycleID)
        else { return nil }
        return (feature, cycleID)
    }

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
        let verification = try journal.featureVerification(cycleID: inFlight.cycleID)
        return FeatureInFlight(
            id: inFlight.feature.issueID,
            issueIDForDisplay: inFlight.feature.issueIDForDisplay ?? inFlight.feature.issueKey,
            title: nil,
            state: inFlight.feature.state,
            rollupState: try rollupState(
                journal, inFlight: inFlight, cards: cards, landings: landed, verification: verification
            ),
            lanes: lanes,
            link: LinearIssueLink.link(
                key: inFlight.feature.issueIDForDisplay ?? inFlight.feature.issueKey,
                url: inFlight.feature.issueURL
            ),
            verification: try verification.map { try counts(of: $0, journal, cycleID: inFlight.cycleID) }
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

    private static func nightCardLink(_ night: NightRecord) -> LinearIssueLink? {
        LinearIssueLink.link(
            key: night.nightCardIssueIDForDisplay ?? night.nightCardIssueKey, url: night.nightCardIssueURL
        )
    }

    private static func night(
        _ night: NightRecord, journal: JournalStore, events: [JournalEventRecord]
    ) throws -> NightPulse {
        // Unstamped invocation failures belong in Health, not in a Night they never reached.
        let nightCard = nightCardLink(night)
        let nightEvents = events.filter { $0.nightID == night.id }
        let failures = JournalFailures(events: nightEvents, nightCard: nightCard)
        let opening = try journal.openingReadyState(nightID: night.id)
        let decisions = try authoringDecisions(journal).filter { $0.openedNightID <= night.id }
        let absence: String = if !decisions.isEmpty {
            "No Cards touched — authoring halted or refused; awaiting an Operator turn in Linear"
        } else if failures.failedRunCount > 0 {
            switch opening {
            case .nonzero: "Act runs failed before any Card was touched — eligible Cards were available"
            case .zero: "Act runs failed before any Card was touched"
            default: "Act runs failed before any Card was touched — opening eligibility unknown"
            }
        } else if opening == .zero {
            "No Cards touched — no eligible Cards at opening"
        } else {
            "No Cards touched"
        }
        return NightPulse(
            id: night.id,
            state: night.state == .opened ? .running : .done,
            startedAt: night.openedAt,
            verdictLine: try verdictLine(
                nightEvents: nightEvents, failedRunCount: failures.failedRunCount,
                recoveredRunCount: failures.recoveredRunCount, journal: journal, authoringDecisions: decisions
            ),
            cardsByDisposition: try dispositions(night: night, journal: journal, events: events),
            cardsAbsence: absence,
            nightCard: nightCard,
            firstFailureHeadline: failures.firstHeadline, failureNotices: failures.notices
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
                .checkRan(let cardID, _, _, _, _, _, _, _),
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
