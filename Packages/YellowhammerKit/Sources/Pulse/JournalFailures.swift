import Domain
import Foundation
import Journal

/// Groups factual failures in the selected Pulse scope; a lane error and its Act wrapper are one run.
struct JournalFailures {
    let flags: [HealthFlag]
    let failedRunCount: Int

    init(events: [JournalEventRecord]) {
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
            return HealthFlag(
                kind: .actFailure, detail: detail,
                occurrenceCount: Set(group.map(\.runKey)).count, lastOccurredAt: last
            )
        }
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
