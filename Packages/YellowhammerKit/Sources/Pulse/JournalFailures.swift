import Domain
import Foundation
import Journal

/// Groups factual failures in the selected Pulse scope; a lane error and its Act wrapper are one run.
/// The failures themselves are `Journal.ActFailures`; this adds what only the Pulse shows — Health rows,
/// each row's fix and the Failure Notices.
struct JournalFailures {
    let flags: [HealthFlag]
    /// Distinct runs that recorded a failure.
    let failedRunCount: Int
    /// Failed runs whose every Health row is recovered.
    let recoveredRunCount: Int
    /// The headline of the first failure by event id, for the Sidebar's mark.
    let firstHeadline: String?
    /// The failures folded into Failure Notices, in Journal order, recovered ones included.
    let notices: [FailureNotice]

    init(events: [JournalEventRecord], nightCard: LinearIssueLink? = nil) {
        let collected = ActFailures(events: events)
        let failures = collected.failures
        failedRunCount = collected.failedRunKeys.count
        firstHeadline = collected.firstHeadline
        let groups = Dictionary(grouping: failures, by: \.detail)
        var recoveredByDetail: [String: Bool] = [:]
        flags = groups.keys.sorted().compactMap { detail in
            guard let group = groups[detail], let last = group.map(\.record.occurredAt).max(),
                let latest = group.max(by: { $0.record.id < $1.record.id }) else { return nil }
            let recoveredAt = collected.recoveredAt(latest)
            recoveredByDetail[detail] = recoveredAt != nil
            return HealthFlag(
                kind: .actFailure, detail: detail,
                occurrenceCount: Set(group.map(\.runKey)).count, lastOccurredAt: last,
                recoveredAt: recoveredAt, cause: latest.cause, fixLink: latest.fixLink(nightCard: nightCard),
                nextAction: latest.nextAction,
                failedAct: latest.record.act
            )
        }
        notices = collected.notices.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            return FailureNotice(
                headline: first.headline, count: Set(group.map(\.runKey)).count,
                firstOccurredAt: first.record.occurredAt, lastOccurredAt: last.record.occurredAt,
                firstEventID: first.record.id, isRecovered: collected.recoveredAt(last) != nil,
                failedAct: first.record.act
            )
        }
        let runDetails = Dictionary(grouping: failures, by: \.runKey).mapValues { $0.map(\.detail) }
        recoveredRunCount = runDetails.values.count { details in
            details.allSatisfy { recoveredByDetail[$0] == true }
        }
    }
}

extension ActFailure {
    /// Where the Health row sends the Operator to fix it; `nightCard` is the Night's board Card, when known.
    func fixLink(nightCard: LinearIssueLink?) -> PulseDestination? {
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
