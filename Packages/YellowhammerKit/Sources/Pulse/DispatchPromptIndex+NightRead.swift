import Config
import Domain
import Foundation
import Journal

struct NightReadContext {
    let journal: JournalStore
    let store: DispatchPromptStore
    let projectID: ProjectID
    let nightID: Int64
    let asOf: Date
}

extension DispatchPromptIndex {
    static func readNight(context: NightReadContext) throws -> DispatchPromptIndex {
        let nightEvents = try context.journal.events(nightID: context.nightID)

        var items: [DispatchPromptItem] = []
        var hasEvidence = false
        let skippedReason = detectSkippedReason(in: nightEvents)
        let rejectedRouteTries = detectRejectedRouteTries(in: nightEvents)

        for eventRecord in nightEvents {
            if let item = processNightEvent(
                eventRecord: eventRecord,
                nightID: context.nightID,
                rejectedRouteTries: rejectedRouteTries,
                context: context
            ) {
                hasEvidence = true
                items.append(item)
            } else if isNightDispatchEvidence(eventRecord.event) {
                hasEvidence = true
            }
        }

        if items.isEmpty {
            let emptyState = resolveNightEmptyState(
                hasEvidence: hasEvidence,
                skippedReason: skippedReason
            )
            return DispatchPromptIndex(
                projectID: context.projectID,
                scope: .night(nightID: context.nightID),
                emptyState: emptyState,
                items: []
            )
        }

        items.sort { $0.time != $1.time ? $0.time < $1.time : $0.id < $1.id }
        return DispatchPromptIndex(
            projectID: context.projectID,
            scope: .night(nightID: context.nightID),
            emptyState: nil,
            items: items
        )
    }

    private static func detectSkippedReason(in events: [JournalEventRecord]) -> String? {
        for eventRecord in events {
            switch eventRecord.event {
            case .authoringNoWorkAvailable:
                return "Nothing was selectable to author."
            case .authoringSkippedFeatureInFlight(let featureIssueID):
                return "Feature already in flight: \(featureIssueID)."
            case .authoringSkippedUnmergedStackFull:
                return "Unmerged feature stack full."
            case .authoringPredecessorIndeterminate(let featureIssueID, _):
                return "Predecessor indeterminate: \(featureIssueID)."
            default:
                break
            }
        }
        return nil
    }

    /// The rejection of each prompt record's own route try, keyed by record id: a rejection reaches only the
    /// capture it pairs with (``PromptCapturePairing``), never another Act's or Feature's try of the same ordinal.
    private static func detectRejectedRouteTries(
        in events: [JournalEventRecord]
    ) -> [String: (cause: AuthoringRouteRejectionCause, reason: String)] {
        let paired = PromptCapturePairing.recordIDs(in: events)
        var rejected: [String: (cause: AuthoringRouteRejectionCause, reason: String)] = [:]
        for eventRecord in events {
            if case .authoringRouteRejected(_, _, _, let cause, let reason) = eventRecord.event,
               let recordID = paired[eventRecord.id] {
                rejected[recordID] = (cause, reason)
            }
        }
        return rejected
    }

    private static func isNightDispatchEvidence(_ event: JournalEvent) -> Bool {
        switch event {
        case .promptCaptureRequested, .routePreflightPromptCaptureRequested, .authoringDispatched,
             .rehearsalFixtureAnswered, .agentCLIProcessSpawned:
            true
        default:
            false
        }
    }

    private static func processNightEvent(
        eventRecord: JournalEventRecord,
        nightID: Int64,
        rejectedRouteTries: [String: (cause: AuthoringRouteRejectionCause, reason: String)],
        context: NightReadContext
    ) -> DispatchPromptItem? {
        switch eventRecord.event {
        case .promptCaptureRequested(
            let recordID, let pass, let cardID, let issueID, let attemptID, let round, let ordinal
        ):
            let itemContext = PromptItemBuildContext(
                recordID: recordID,
                pass: pass,
                round: round,
                ordinal: ordinal,
                issueID: issueID,
                cardID: cardID,
                attemptID: attemptID,
                nightID: nightID,
                fallbackRoute: "",
                eventTime: eventRecord.occurredAt
            )
            var item = makeItem(
                context: itemContext, store: context.store, projectID: context.projectID, asOf: context.asOf
            )
            if let rej = rejectedRouteTries[recordID] {
                item = itemApplyingRejected(item: item, cause: rej.cause, reason: rej.reason)
            }
            return item

        case .routePreflightPromptCaptureRequested(let recordID, let route):
            return makePreflightItem(
                recordID: recordID, route: route, eventTime: eventRecord.occurredAt, nightID: nightID, context: context
            )

        case .authoringDispatched(let pass, let route, let ordinal, let fixture):
            guard let fixture else { return nil }
            let params = RehearsalParams(
                id: "rehearsal-\(eventRecord.id)",
                pass: pass,
                route: route,
                routeTry: ordinal,
                fixture: fixture,
                time: eventRecord.occurredAt
            )
            return makeRehearsalItem(params: params, context: context)

        case .rehearsalFixtureAnswered(let cardID, let issueID, let attemptID, let pass, let fixture):
            let target = CardAttemptTarget(cardID: cardID, issueID: issueID, attemptID: attemptID)
            return makeRehearsalCardItem(
                eventRecord: eventRecord,
                pass: pass,
                target: target,
                fixture: fixture,
                context: context
            )

        default:
            return nil
        }
    }

    /// A Route Pre-flight dispatches as the architect pass, but is its own prompt family.
    private static func makePreflightItem(
        recordID: String, route: Route, eventTime: Date, nightID: Int64, context: NightReadContext
    ) -> DispatchPromptItem {
        let itemContext = PromptItemBuildContext(
            recordID: recordID,
            pass: .architect,
            round: nil,
            ordinal: nil,
            issueID: nil,
            cardID: nil,
            attemptID: nil,
            nightID: nightID,
            fallbackRoute: route.description,
            eventTime: eventTime,
            family: .routePreflight
        )
        return makeItem(context: itemContext, store: context.store, projectID: context.projectID, asOf: context.asOf)
    }

    private struct RehearsalParams {
        let id: String
        let pass: RunPass
        let route: String
        let routeTry: Int?
        let fixture: String
        let time: Date
    }

    private struct CardAttemptTarget {
        let cardID: Int64
        let issueID: String
        let attemptID: Int64
    }

    private static func itemApplyingRejected(
        item: DispatchPromptItem,
        cause: AuthoringRouteRejectionCause,
        reason: String
    ) -> DispatchPromptItem {
        // Only an unavailable Route never started; any other rejection judged a run that did, so the record's
        // own launch state stands.
        let launch: DispatchLaunch?
        if cause == .unavailable, item.launch == .pending || item.launch == nil {
            launch = .notLaunched(cause: "\(cause.phrase): \(reason)")
        } else {
            launch = item.launch
        }
        return DispatchPromptItem(
            id: item.id,
            recordID: item.recordID,
            pass: item.pass,
            round: item.round,
            routeTry: item.routeTry,
            route: item.route,
            time: item.time,
            session: item.session,
            state: item.state,
            family: item.family,
            projectID: item.projectID,
            defaultVersion: item.defaultVersion,
            projectInstructions: item.projectInstructions,
            launch: launch,
            nightID: item.nightID,
            featureIssueID: item.featureIssueID,
            workCardIssueID: item.workCardIssueID,
            cardID: item.cardID,
            attemptID: item.attemptID,
            instruction: item.instruction,
            outputSchema: item.outputSchema,
            rejectionCause: cause
        )
    }

    private static func makeRehearsalItem(
        params: RehearsalParams,
        context: NightReadContext
    ) -> DispatchPromptItem {
        DispatchPromptItem(
            id: params.id,
            recordID: nil,
            pass: params.pass,
            round: nil,
            routeTry: params.routeTry,
            route: params.route,
            time: params.time,
            session: .new,
            state: .rehearsal(fixture: params.fixture),
            family: PromptFamily(pass: params.pass),
            projectID: context.projectID,
            defaultVersion: nil,
            projectInstructions: .absent,
            launch: nil,
            nightID: context.nightID,
            featureIssueID: nil,
            workCardIssueID: nil,
            cardID: nil,
            attemptID: nil,
            instruction: nil,
            outputSchema: nil
        )
    }

    private static func makeRehearsalCardItem(
        eventRecord: JournalEventRecord,
        pass: RunPass,
        target: CardAttemptTarget,
        fixture: String,
        context: NightReadContext
    ) -> DispatchPromptItem {
        DispatchPromptItem(
            id: "rehearsal-\(eventRecord.id)",
            recordID: nil,
            pass: pass,
            round: nil,
            routeTry: nil,
            route: "rehearsal",
            time: eventRecord.occurredAt,
            session: .new,
            state: .rehearsal(fixture: fixture),
            family: PromptFamily(pass: pass),
            projectID: context.projectID,
            defaultVersion: nil,
            projectInstructions: .absent,
            launch: nil,
            nightID: context.nightID,
            featureIssueID: nil,
            workCardIssueID: target.issueID,
            cardID: target.cardID,
            attemptID: target.attemptID,
            instruction: nil,
            outputSchema: nil
        )
    }

    private static func resolveNightEmptyState(
        hasEvidence: Bool,
        skippedReason: String?
    ) -> DispatchPromptIndex.EmptyState {
        if hasEvidence {
            return .legacy
        }
        if let skippedReason {
            return .skipped(reason: skippedReason)
        }
        return .noDispatchesYet
    }
}
