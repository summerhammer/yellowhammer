import Domain
import Foundation
import Journal

extension PulseSnapshot {
    /// The Night's `verdictLine`: Journal facts joined by " · ", never the engine's verdict_line.
    /// First the Feature fact — a Feature returned with unmet clauses, else a Feature verified with every
    /// clause met — then open authoring decisions and the count of failed Act runs. Nil when no fact applies.
    static func verdictLine(
        nightEvents: [JournalEventRecord], failedRunCount: Int, recoveredRunCount: Int, journal: JournalStore,
        authoringDecisions: [AuthoringDecision] = []
    ) throws -> String? {
        var facts: [String] = []
        if let feature = try featureFact(nightEvents: nightEvents, journal: journal) {
            facts.append(feature)
        }
        for decision in authoringDecisions {
            let outcome = decision.kind == .halt ? "halted" : "refused"
            facts.append("Authoring Feature “\(decision.title)” \(outcome) — awaiting an Operator turn in Linear")
        }
        if failedRunCount > 0 {
            let failed = "\(failedRunCount) Act run\(failedRunCount == 1 ? "" : "s") failed"
            let recovered = recoveredRunCount > 0 ? ", \(recoveredRunCount) recovered" : ""
            facts.append("\(failed)\(recovered) — see Health")
        }
        return facts.isEmpty ? nil : facts.joined(separator: " · ")
    }

    /// The payload of a `featureReturned` event.
    private struct ReturnedEvent {
        let cycleID: Int64
        let issueID: String
        let unmet: Int
        let unresolved: Int
        let notChecked: Int
    }

    /// "Feature YLH-347 returned — 4 of 22 clauses unmet", or "Feature YLH-347 verified — all 22 clauses met".
    /// The `featureVerified` payload carries no Feature id, so the Feature is found through its Cycle.
    private static func featureFact(nightEvents: [JournalEventRecord], journal: JournalStore) throws -> String? {
        var verified: [Int64: VerificationCounts] = [:]
        var returned: ReturnedEvent?
        for record in nightEvents {
            switch record.event {
            case .featureVerified(let cycleID, let met, let unmet, let unresolved, let notChecked):
                verified[cycleID] = VerificationCounts(
                    met: met, unmet: unmet, unresolved: unresolved, notChecked: notChecked
                )
            case .featureReturned(let cycleID, let issueID, let unmet, let unresolved, let notChecked):
                returned = ReturnedEvent(
                    cycleID: cycleID, issueID: issueID, unmet: unmet, unresolved: unresolved, notChecked: notChecked
                )
            default:
                break
            }
        }
        if let returned {
            let name = try journal.feature(issueID: returned.issueID)?.displayIdentifier ?? returned.issueID
            let notChecked = returned.notChecked > 0 ? ", \(returned.notChecked) not checked" : ""
            guard let counts = verified[returned.cycleID] else {
                return "Feature \(name) returned — \(returned.unmet + returned.unresolved) clauses unmet\(notChecked)"
            }
            let total = counts.total
            let unresolved = returned.unresolved > 0 ? ", \(returned.unresolved) unresolved" : ""
            return "Feature \(name) returned — \(returned.unmet) of \(total) clauses unmet\(unresolved)\(notChecked)"
        }
        let clean = verified.sorted(by: { $0.key < $1.key })
            .filter { $0.value.unmet == 0 && $0.value.unresolved == 0 && $0.value.notChecked == 0 }
        // Every Feature verified this Night counts, not only the last: several can land in one Night.
        if clean.count > 1 {
            return "\(clean.count) Features verified — all \(clean.reduce(0) { $0 + $1.value.met }) clauses met"
        }
        if let (cycleID, counts) = clean.last {
            let name = try journal.feature(cycleID: cycleID)?.displayIdentifier
            return "Feature \(name.map { "\($0) " } ?? "")verified — all \(counts.met) clauses met"
        }
        return nil
    }
}
