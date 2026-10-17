import Domain
import Foundation

/// One Act failure the Journal records (morning-report/disclose-a-failure#act-failure): a failed lane, a
/// fault inside an Act, or an Act that could not complete.
public struct ActFailure: Sendable {
    public let record: JournalEventRecord
    public let cause: ActFailureCause
    /// The Repo of a failed lane; nil for every other failure.
    public let repository: String?
    public let reason: String

    /// The run that recorded it, or — for an event outside any run — the event itself.
    public var runKey: String { record.runID?.rawValue ?? "event-\(record.id)" }

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

    /// The failure's identity: failures with one `detail` are one reason, however often it recurs.
    public var detail: String {
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

    /// The failure in one line, without the reason's detail.
    public var headline: String {
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
}

/// The Act failures in a set of Journal events, with what a reader needs to disclose them: which are
/// recovered, how they fold into notices, and which runs failed.
public struct ActFailures: Sendable {
    /// What a Health row shows: lane failures, faults, and Act failures that no lane error explains.
    public let failures: [ActFailure]
    /// Every failure, wrapped Act failures included — what counting runs and recovery use.
    public let all: [ActFailure]
    private let recovery: Recovery

    public init(events: [JournalEventRecord]) {
        let byRun = Dictionary(grouping: events.filter { $0.runID != nil }, by: { $0.runID?.rawValue ?? "" })
        func failure(_ record: JournalEventRecord, repository: String? = nil, reason: String) -> ActFailure? {
            let siblings = record.runID.map { byRun[$0.rawValue] ?? [] } ?? []
            guard let cause = ActFailureCause.classify(record.event, runEvents: siblings.map(\.event)) else {
                return nil
            }
            return ActFailure(record: record, cause: cause, repository: repository, reason: reason)
        }
        let lanes = events.compactMap { record -> ActFailure? in
            guard case .repoLaneEnded(let repo, _, let reason?, _) = record.event else { return nil }
            return failure(record, repository: repo, reason: reason)
        }
        let acts = events.compactMap { record -> ActFailure? in
            guard case .actIncomplete(let reason) = record.event else { return nil }
            return failure(record, reason: reason)
        }
        let faults = events.compactMap { record -> ActFailure? in
            switch record.event {
            case .featureBreakdownRejected(_, let reason), .featureAuthoringFailed(_, _, let reason),
                .featureSelectionFailed(let reason), .authoringInvariantBroken(_, _, let reason):
                failure(record, reason: reason)
            default: nil
            }
        }
        failures = lanes + faults + Self.unwrapped(acts, lanes: lanes)
        all = lanes + faults + acts
        recovery = Recovery(events: events, failures: all)
    }

    /// The first failure of one run by event id, as `yh status` words the run's ending; nil when the run
    /// recorded none. A build Act's wrapper of a lane error does not count: the lane is the failure.
    public static func firstFailure(inRun runEvents: [JournalEventRecord]) -> ActFailure? {
        ActFailures(events: runEvents).failures.min { $0.record.id < $1.record.id }
    }

    /// The headline of the first failure by event id.
    public var firstHeadline: String? {
        failures.min { $0.record.id < $1.record.id }?.headline
    }

    /// Distinct runs that recorded a failure.
    public var failedRunKeys: Set<String> { Set(all.map(\.runKey)) }

    /// When a later run of the same Night got past `failure` (disclose-a-failure#recovered); nil while
    /// it has not.
    public func recoveredAt(_ failure: ActFailure) -> Date? {
        recovery.date(for: failure)
    }

    /// The failures grouped, in Journal order, into one group per notice: a failure continues the notice
    /// of the same reason (`detail`) that the run before it, or its own run, extended; a run without that
    /// reason in between starts a new one (morning-report/disclose-a-failure#one-notice-per-run).
    public var notices: [[ActFailure]] { Self.fold(failures) }
}

extension ActFailures {
    /// The build Act's wrapper includes each lane's verbatim reason. Preserve an unrelated Act failure even
    /// if another lane failed during the same run.
    static func unwrapped(_ acts: [ActFailure], lanes: [ActFailure]) -> [ActFailure] {
        acts.filter { act in
            !lanes.contains { lane in
                act.record.runID != nil && act.record.runID == lane.record.runID
                    && (act.reason == lane.reason
                        || (act.reason.hasPrefix("the build Act's lanes failed: ")
                            && act.reason.contains("\(lane.repository ?? ""): \(lane.reason)")))
            }
        }
    }

    static func fold(_ failures: [ActFailure]) -> [[ActFailure]] {
        var runOrder: [String] = []
        var byRun: [String: [ActFailure]] = [:]
        for failure in failures.sorted(by: { $0.record.id < $1.record.id }) {
            if byRun[failure.runKey] == nil { runOrder.append(failure.runKey) }
            byRun[failure.runKey, default: []].append(failure)
        }
        var groups: [[ActFailure]] = []
        // A reason's notice, while the latest run extended it.
        var open: [String: Int] = [:]
        for run in runOrder {
            var extended: [String: Int] = [:]
            for failure in byRun[run] ?? [] {
                if let index = extended[failure.detail] ?? open[failure.detail] {
                    groups[index].append(failure)
                    extended[failure.detail] = index
                } else {
                    groups.append([failure])
                    extended[failure.detail] = groups.count - 1
                }
            }
            open = extended
        }
        return groups
    }
}

/// When a later run of the same Night got past each failure (disclose-a-failure#recovered).
private struct Recovery: Sendable {
    let events: [JournalEventRecord]
    let failures: [ActFailure]

    /// The recovery of `failure`: the first checkpoint, in event order, of another run in its scope that is
    /// later than every failure of the same class in that scope, and whose run did not fail the same way.
    func date(for failure: ActFailure) -> Date? {
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
