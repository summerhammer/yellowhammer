import Domain
import Foundation
import Journal

/// Records a Refusal — the thin-spec finding — durably before any board write, then puts the Feature in
/// Waiting on You naming the uncitable clauses and the re-selection depth (roadmap P9.5, P9.7, P9.8;
/// glossary: Refusal). Its own path, not a kind of halt: it shares only ``AuthoringStopBoard`` with
/// ``AuthoringHalt``, and it alone moves the consecutive-refusals count.
///
/// Once the Refusal has expired, a repeat only moves the count: the Feature Issue stays Blocked and
/// nothing is written to the board.
enum RefusalRecording {
    static func record(
        feature: FeatureName, finding: RefusalFinding, context: ActContext,
        operatorIdentity: OperatorIdentity = .none, consecutiveRefusalsMax: Int = 3
    ) async throws -> FeatureAuthoringOutcome {
        let body = finding.description
        let outcome = try context.journal.recordRefusal(
            feature: feature, content: body, uncitableClauses: finding.clauseListing,
            reselectionDepth: finding.reselectionDepth, consecutiveRefusalsMax: consecutiveRefusalsMax,
            nightID: context.night.id, act: context.act, runID: context.runID
        )
        if outcome.alreadyExpired { return .refused }
        let reopenKey = outcome.newlyOpened ? "feature:\(feature.rawValue):refusal:\(outcome.record.id):reenter" : nil
        try await AuthoringStopBoard.post(
            feature: feature, body: body, context: context, reopenKey: reopenKey,
            operatorIdentity: operatorIdentity
        ) {
            try context.journal.recordRefusalIssue(feature: feature, issueID: $0)
        }
        return .refused
    }
}
