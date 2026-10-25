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
        let nightRunIDs = Set(nightEvents.compactMap { $0.runID?.rawValue })

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

        appendPreflightItems(
            items: &items,
            hasEvidence: &hasEvidence,
            context: context,
            nightRunIDs: nightRunIDs
        )

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

    private static func detectRejectedRouteTries(
        in events: [JournalEventRecord]
    ) -> [RunPass: [Int: (cause: AuthoringRouteRejectionCause, reason: String)]] {
        var rejected: [RunPass: [Int: (cause: AuthoringRouteRejectionCause, reason: String)]] = [:]
        for eventRecord in events {
            if case .authoringRouteRejected(let pass, _, let ordinal, let cause, let reason) = eventRecord.event {
                rejected[pass, default: [:]][ordinal] = (cause, reason)
            }
        }
        return rejected
    }

    private static func isNightDispatchEvidence(_ event: JournalEvent) -> Bool {
        switch event {
        case .promptCaptureRequested, .authoringDispatched, .rehearsalFixtureAnswered, .agentCLIProcessSpawned:
            true
        default:
            false
        }
    }

    private static func processNightEvent(
        eventRecord: JournalEventRecord,
        nightID: Int64,
        rejectedRouteTries: [RunPass: [Int: (cause: AuthoringRouteRejectionCause, reason: String)]],
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
                context: itemContext,
                store: context.store,
                projectID: context.projectID,
                asOf: context.asOf
            )
            if let ord = ordinal, let rej = rejectedRouteTries[pass]?[ord],
               item.launch == .pending || item.launch == nil {
                item = itemApplyingRejected(item: item, cause: rej.cause, reason: rej.reason)
            }
            return item

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
        DispatchPromptItem(
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
            launch: .notLaunched(cause: "\(cause.phrase): \(reason)"),
            nightID: item.nightID,
            featureIssueID: item.featureIssueID,
            workCardIssueID: item.workCardIssueID,
            cardID: item.cardID,
            attemptID: item.attemptID,
            instruction: item.instruction,
            outputSchema: item.outputSchema
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

    private static func appendPreflightItems(
        items: inout [DispatchPromptItem],
        hasEvidence: inout Bool,
        context: NightReadContext,
        nightRunIDs: Set<String>
    ) {
        for entry in context.store.entries(in: .project(context.projectID)) {
            guard case .available(let rec) = entry.lookup,
                  rec.provenance.family == .routePreflight,
                  let runID = rec.provenance.runID,
                  nightRunIDs.contains(runID) else { continue }

            hasEvidence = true
            let state: DispatchPromptIndex.EntryState = rec.isExpired(at: context.asOf)
                ? .expired(dispatchedAt: rec.dispatchedAt)
                : .recorded(rec)

            items.append(
                DispatchPromptItem(
                    id: rec.id,
                    recordID: rec.id,
                    pass: rec.pass,
                    round: rec.provenance.round,
                    routeTry: rec.provenance.routeTry,
                    route: rec.route,
                    time: rec.dispatchedAt,
                    session: rec.session,
                    state: state,
                    family: rec.provenance.family,
                    projectID: context.projectID,
                    defaultVersion: rec.defaultVersion,
                    projectInstructions: rec.projectInstructions,
                    launch: rec.launch,
                    nightID: context.nightID,
                    featureIssueID: rec.provenance.featureIssueID,
                    workCardIssueID: rec.provenance.workCardIssueID,
                    cardID: rec.provenance.cardID,
                    attemptID: rec.provenance.attemptID,
                    instruction: state == .recorded(rec) ? rec.instruction : nil,
                    outputSchema: state == .recorded(rec) ? rec.outputSchema : nil
                )
            )
        }
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
