import Domain
import Foundation
import Journal

/// Groups factual failures in the selected Pulse scope; a lane error and its Act wrapper are one run.
struct JournalFailures {
    let flags: [HealthFlag]
    /// Distinct runs that recorded a failure.
    let failedRunCount: Int
    /// Failed runs whose every Health row is recovered.
    let recoveredRunCount: Int
    /// The headline of the first failure by event id, for the Sidebar's mark.
    let firstHeadline: String?

    init(events: [JournalEventRecord], nightCard: LinearIssueLink? = nil) {
        let byRun = Dictionary(grouping: events.filter { $0.runID != nil }, by: { $0.runID?.rawValue ?? "" })
        func failure(_ record: JournalEventRecord, repository: String? = nil, reason: String) -> JournalFailure? {
            let siblings = record.runID.map { byRun[$0.rawValue] ?? [] } ?? []
            guard let cause = ActFailureCause.classify(record.event, runEvents: siblings.map(\.event)) else {
                return nil
            }
            return JournalFailure(
                record: record, cause: cause, repository: repository, reason: reason, nightCard: nightCard
            )
        }
        let lanes = events.compactMap { record -> JournalFailure? in
            guard case .repoLaneEnded(let repo, _, let reason?, _) = record.event else { return nil }
            return failure(record, repository: repo, reason: reason)
        }
        let acts = events.compactMap { record -> JournalFailure? in
            guard case .actIncomplete(let reason) = record.event else { return nil }
            return failure(record, reason: reason)
        }
        let faults = events.compactMap { record -> JournalFailure? in
            switch record.event {
            case .featureBreakdownRejected(_, let reason), .featureAuthoringFailed(_, _, let reason),
                .featureSelectionFailed(let reason), .authoringInvariantBroken(_, _, let reason):
                failure(record, reason: reason)
            default: nil
            }
        }
        let failures = lanes + faults + Self.unwrapped(acts, lanes: lanes)
        let recovery = Recovery(events: events, failures: lanes + faults + acts)
        failedRunCount = Set((lanes + faults + acts).map(\.runKey)).count
        firstHeadline = failures.min { $0.record.id < $1.record.id }?.headline
        let groups = Dictionary(grouping: failures, by: \.detail)
        var recoveredByDetail: [String: Bool] = [:]
        flags = groups.keys.sorted().compactMap { detail in
            guard let group = groups[detail], let last = group.map(\.record.occurredAt).max(),
                let latest = group.max(by: { $0.record.id < $1.record.id }) else { return nil }
            let recoveredAt = recovery.date(for: latest)
            recoveredByDetail[detail] = recoveredAt != nil
            return HealthFlag(
                kind: .actFailure, detail: detail,
                occurrenceCount: Set(group.map(\.runKey)).count, lastOccurredAt: last,
                recoveredAt: recoveredAt, cause: latest.cause, fixLink: latest.fixLink,
                nextAction: latest.nextAction
            )
        }
        let runDetails = Dictionary(grouping: failures, by: \.runKey).mapValues { $0.map(\.detail) }
        recoveredRunCount = runDetails.values.count { details in
            details.allSatisfy { recoveredByDetail[$0] == true }
        }
    }
}

extension JournalFailures {
    /// The build Act's wrapper includes each lane's verbatim reason. Preserve an unrelated Act failure even
    /// if another lane failed during the same run.
    static func unwrapped(_ acts: [JournalFailure], lanes: [JournalFailure]) -> [JournalFailure] {
        acts.filter { act in
            !lanes.contains { lane in
                act.record.runID != nil && act.record.runID == lane.record.runID
                    && (act.reason == lane.reason
                        || (act.reason.hasPrefix("the build Act's lanes failed: ")
                            && act.reason.contains("\(lane.repository ?? ""): \(lane.reason)")))
            }
        }
    }
}

/// When a later run of the same Night got past each failure (disclose-a-failure#recovered).
private struct Recovery {
    let events: [JournalEventRecord]
    let failures: [JournalFailure]

    /// The recovery of `failure`: the first checkpoint, in event order, of another run in its scope that is
    /// later than every failure of the same class in that scope, and whose run did not fail the same way.
    func date(for failure: JournalFailure) -> Date? {
        guard let nightID = failure.record.nightID, let runID = failure.record.runID,
            let act = failure.record.act, failure.cause != .authoringInvariantBroken else { return nil }
        let cause = failure.cause
        let wide = cause == .boardScopeUnresolved
        func inScope(_ record: JournalEventRecord) -> Bool {
            record.nightID == nightID && (wide || record.act == act)
        }
        let sameClass = failures.filter { inScope($0.record) && Self.sameClass($0.cause, cause) }
        let latest = sameClass.map(\.record.id).max() ?? failure.record.id
        let failedRuns = Set(sameClass.compactMap(\.record.runID))
        var seen: [RunID] = []
        for record in events where inScope(record) {
            guard let run = record.runID, run != runID, !seen.contains(run) else { continue }
            seen.append(run)
        }
        for run in seen where !failedRuns.contains(run) {
            let runEvents = events.filter { $0.runID == run && inScope($0) }
            guard let checkpoint = Self.checkpoint(cause, runEvents), checkpoint.id > failure.record.id,
                checkpoint.id > latest else { continue }
            return checkpoint.occurredAt
        }
        return nil
    }

    private static func sameClass(_ lhs: ActFailureCause, _ rhs: ActFailureCause) -> Bool {
        let legacy: Set<ActFailureCause> = [.laneFailed, .actIncomplete]
        return lhs == rhs || (legacy.contains(lhs) && legacy.contains(rhs))
    }

    /// What a run records before, or instead of, getting past the board preflight. `linearReached` is here
    /// because the board-scope check appends it before it refuses an unresolved scope, so it proves nothing.
    private static let preflight: Set<JournalEventType> = [
        .actStarted, .linearReached, .boardScopeUnresolved, .actIncomplete, .actStoodDown,
        .linearAuthorizationHalted, .linearUnreachableHalted, .notificationDeliveryFailed
    ]

    private static func checkpoint(_ cause: ActFailureCause, _ run: [JournalEventRecord]) -> JournalEventRecord? {
        func first(_ types: JournalEventType...) -> JournalEventRecord? {
            run.first { types.contains($0.type) }
        }
        switch cause {
        case .boardScopeUnresolved: return run.first { !preflight.contains($0.type) }
        case .selectionFailed: return first(.featureSelected)
        case .overDescriptionBudget, .invalidBreakdown, .authoringRoutesFailed:
            return first(.featureAuthoringAccepted) ?? first(.featureAuthored)
        case .noAuthoringRoute: return first(.authoringDispatched)
        case .authoringTransactionFailed: return first(.featureAuthored)
        case .authoringInvariantBroken: return nil
        case .laneFailed, .actIncomplete: return first(.actEnded)
        }
    }
}

struct JournalFailure {
    let record: JournalEventRecord
    let cause: ActFailureCause
    let repository: String?
    let reason: String
    let nightCard: LinearIssueLink?

    var runKey: String { record.runID?.rawValue ?? "event-\(record.id)" }

    private var act: String { record.act?.rawValue ?? "Act" }

    private var feature: String? {
        switch record.event {
        case .featureBreakdownRejected(let name, _), .featureAuthoringFailed(let name, _, _): name
        default: nil
        }
    }

    private var firstLine: String {
        reason.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? reason
    }

    var detail: String {
        let named = feature ?? ""
        switch cause {
        case .overDescriptionBudget:
            let overrun = DescriptionBudgetOverrun.parse(reason)?.oneLine ?? "over the description budget"
            return "\(act): authoring \"\(named)\" faulted: \(overrun)"
        case .invalidBreakdown, .authoringRoutesFailed:
            return "\(act): authoring \"\(named)\" faulted: \(cause.phrase) — "
                + DescriptionBudgetOverrun.oneLineReason(reason)
        case .noAuthoringRoute:
            return "\(act): authoring \"\(named)\" faulted: \(cause.phrase)"
        case .authoringTransactionFailed:
            return "\(act): authoring \"\(named)\" failed: \(firstLine)"
        case .selectionFailed:
            return "\(act): selecting a Feature failed: \(DescriptionBudgetOverrun.oneLineReason(reason))"
        case .authoringInvariantBroken:
            return "\(act): a Work Card broke an authoring invariant: \(reason)"
        case .boardScopeUnresolved, .laneFailed, .actIncomplete:
            return "\(act)\(repository.map { " · \($0)" } ?? ""): \(reason)"
        }
    }

    var headline: String {
        switch cause {
        case .boardScopeUnresolved: "The \(act) Act did no work: the board scope is unresolved"
        case .overDescriptionBudget, .noAuthoringRoute, .invalidBreakdown, .authoringRoutesFailed,
            .authoringTransactionFailed:
            "Authoring “\(feature ?? "")” failed: \(cause.phrase)"
        case .selectionFailed: "Selecting a Feature failed"
        case .authoringInvariantBroken: "A Work Card broke an authoring invariant"
        case .laneFailed: "The build Act's \(repository ?? "") lane failed"
        case .actIncomplete: "The \(act) Act could not complete"
        }
    }

    var fixLink: PulseDestination? {
        switch cause {
        case .overDescriptionBudget: .linearWorkspaces
        case .authoringInvariantBroken:
            if case .authoringInvariantBroken(_, let issueID, _) = record.event {
                .inspector(.card(issueID))
            } else {
                nil
            }
        default: nightCard.map { .nightCard($0.url) }
        }
    }

    var nextAction: String? {
        cause == .overDescriptionBudget
            ? "Shorten or split the Feature's spec first, or raise the description budget in "
            + "Settings → Board connections"
            : nil
    }
}
