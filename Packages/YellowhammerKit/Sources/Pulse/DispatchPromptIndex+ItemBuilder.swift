import Config
import Domain
import Foundation

struct PromptItemBuildContext {
    let recordID: String
    let pass: RunPass
    let round: Int?
    let ordinal: Int?
    let issueID: String?
    let cardID: Int64?
    let attemptID: Int64?
    let nightID: Int64?
    let fallbackRoute: String
    let eventTime: Date
    /// The prompt family when it is not the pass's own (a Route Pre-flight dispatches as the architect pass).
    var family: PromptFamily?
}

extension DispatchPromptIndex {
    static func makeItem(
        context: PromptItemBuildContext,
        store: DispatchPromptStore,
        projectID: ProjectID,
        asOf: Date
    ) -> DispatchPromptItem {
        let lookup = store.lookup(id: context.recordID, scope: .project(projectID))
        let isPast30Days = asOf.timeIntervalSince(context.eventTime) >= DispatchPromptRecord.retention
        let state = resolveEntryState(
            lookup: lookup, eventTime: context.eventTime, asOf: asOf, isPast30Days: isPast30Days
        )
        let isResumed = context.pass == .worker && (context.round ?? 1) > 1

        switch state {
        case .recorded(let record):
            return itemFromRecord(record: record, context: context, projectID: projectID, state: state)
        case .expired(let dispatchedAt):
            return itemFromFallback(
                context: context, projectID: projectID, state: state, time: dispatchedAt, isResumed: isResumed
            )
        case .deleted, .unavailable, .rehearsal:
            return itemFromFallback(
                context: context, projectID: projectID, state: state, time: context.eventTime, isResumed: isResumed
            )
        }
    }

    private static func resolveEntryState(
        lookup: DispatchPromptLookup,
        eventTime: Date,
        asOf: Date,
        isPast30Days: Bool
    ) -> DispatchPromptIndex.EntryState {
        switch lookup {
        case .available(let rec):
            if rec.isExpired(at: asOf) || isPast30Days {
                return .expired(dispatchedAt: rec.dispatchedAt)
            }
            return .recorded(rec)
        case .expired(let dispatchedAt):
            return .expired(dispatchedAt: dispatchedAt)
        case .deleted(let deletedAt):
            return .deleted(deletedAt: deletedAt)
        case .missing:
            return isPast30Days ? .expired(dispatchedAt: eventTime) : .unavailable(cause: nil)
        case .unreadable(let cause):
            return isPast30Days ? .expired(dispatchedAt: eventTime) : .unavailable(cause: cause)
        }
    }

    private static func itemFromRecord(
        record: DispatchPromptRecord,
        context: PromptItemBuildContext,
        projectID: ProjectID,
        state: DispatchPromptIndex.EntryState
    ) -> DispatchPromptItem {
        DispatchPromptItem(
            id: record.id,
            recordID: record.id,
            pass: record.pass,
            round: record.provenance.round ?? context.round,
            routeTry: record.provenance.routeTry ?? context.ordinal,
            route: record.route,
            time: record.dispatchedAt,
            session: record.session,
            state: state,
            family: record.provenance.family,
            projectID: projectID,
            defaultVersion: record.defaultVersion,
            projectInstructions: record.projectInstructions,
            launch: record.launch,
            nightID: record.provenance.nightID ?? context.nightID,
            featureIssueID: record.provenance.featureIssueID,
            workCardIssueID: record.provenance.workCardIssueID ?? context.issueID,
            cardID: record.provenance.cardID ?? context.cardID,
            attemptID: record.provenance.attemptID ?? context.attemptID,
            instruction: record.instruction,
            outputSchema: record.outputSchema
        )
    }

    private static func itemFromFallback(
        context: PromptItemBuildContext,
        projectID: ProjectID,
        state: DispatchPromptIndex.EntryState,
        time: Date,
        isResumed: Bool
    ) -> DispatchPromptItem {
        DispatchPromptItem(
            id: context.recordID,
            recordID: context.recordID,
            pass: context.pass,
            round: context.round,
            routeTry: context.ordinal,
            route: context.fallbackRoute,
            time: time,
            session: isResumed ? .resumed : .new,
            state: state,
            family: context.family ?? PromptFamily(pass: context.pass),
            projectID: projectID,
            defaultVersion: nil,
            projectInstructions: .absent,
            launch: nil,
            nightID: context.nightID,
            featureIssueID: nil,
            workCardIssueID: context.issueID,
            cardID: context.cardID,
            attemptID: context.attemptID,
            instruction: nil,
            outputSchema: nil
        )
    }
}
