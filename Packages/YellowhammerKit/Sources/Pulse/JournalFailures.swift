import Domain
import Foundation
import Journal

/// Groups factual failures in the selected Pulse scope; a lane error and its Act wrapper are one run.
struct JournalFailures {
    let flags: [HealthFlag]
    let failedRunCount: Int

    init(events: [JournalEventRecord]) {
        let successes = events.compactMap { record -> JournalEventRecord? in
            guard case .actEnded = record.event else { return nil }
            return record
        }
        let failureEvents = events.filter { record in
            switch record.event {
            case .actIncomplete: true
            case .repoLaneEnded(_, _, .some, _): true
            default: false
            }
        }
        let lanes = events.compactMap { record -> Failure? in
            guard case .repoLaneEnded(let repo, _, let reason?, _) = record.event else { return nil }
            return Failure(record: record, repository: repo, reason: reason)
        }
        let acts = events.compactMap { record -> Failure? in
            guard case .actIncomplete(let reason) = record.event else { return nil }
            return Failure(record: record, repository: nil, reason: reason)
        }
        let failures = lanes + acts.filter { act in
            // The build Act's wrapper includes each lane's verbatim reason. Preserve an unrelated
            // Act failure even if another lane failed during the same run.
            !lanes.contains { lane in
                act.record.runID != nil && act.record.runID == lane.record.runID
                    && (act.reason == lane.reason
                        || (act.reason.hasPrefix("the build Act's lanes failed: ")
                            && act.reason.contains("\(lane.repository ?? ""): \(lane.reason)")))
            }
        }
        failedRunCount = Set((lanes + acts).map(\.runKey)).count
        let groups = Dictionary(grouping: failures, by: \.detail)
        flags = groups.keys.sorted().compactMap { detail in
            guard let group = groups[detail], let last = group.map(\.record.occurredAt).max() else { return nil }
            let recoveredAt = Self.recoveryDate(
                for: group, successes: successes, failureEvents: failureEvents
            )
            return HealthFlag(
                kind: .actFailure, detail: detail,
                occurrenceCount: Set(group.map(\.runKey)).count, lastOccurredAt: last,
                recoveredAt: recoveredAt
            )
        }
    }

    private static func recoveryDate(
        for failures: [Failure], successes: [JournalEventRecord], failureEvents: [JournalEventRecord]
    ) -> Date? {
        guard let latest = failures.max(by: { $0.record.id < $1.record.id }),
              let nightID = latest.record.nightID, let act = latest.record.act,
              let runID = latest.record.runID else { return nil }
        return successes.sorted { $0.id < $1.id }.first { success in
            success.nightID == nightID && success.act == act
                && success.runID != nil && success.runID != runID && success.id > latest.record.id
                && !failureEvents.contains {
                    $0.nightID == nightID && $0.act == act && $0.runID == success.runID
                }
                && !failureEvents.contains {
                    $0.nightID == nightID && $0.act == act && $0.id > success.id
                }
        }?.occurredAt
    }
}

private struct Failure {
    let record: JournalEventRecord
    let repository: String?
    let reason: String

    var runKey: String { record.runID?.rawValue ?? "event-\(record.id)" }
    var detail: String {
        let act = record.act?.rawValue ?? "Act"
        return "\(act)\(repository.map { " · \($0)" } ?? ""): \(reason)"
    }
}
