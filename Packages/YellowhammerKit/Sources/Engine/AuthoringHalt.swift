import Domain
import Foundation
import Journal

/// Records an Authoring Halt durably before any board write, then — only when this invocation has an
/// Outbox and a Board — puts the Feature in Waiting on You naming the cause. Allocates no Worktree,
/// dispatches nothing and records no Attempt.
///
/// Shared by ``FeatureSelection`` (the seam and repository-determination halts, roadmap P9.3) and
/// ``AuthoringTransaction`` (the unreadable contract, P9.6). Not the thin-spec finding: that is a
/// Refusal, recorded by ``RefusalRecording``. The two share only ``AuthoringStopBoard``. A halt never
/// touches a Refusal or any consecutive count.
///
/// Once a halt has expired, a repeat writes nothing to the board at all: the Feature Issue stays
/// Blocked, no re-create into Waiting on You and no repeated comment.
enum AuthoringHalt {
    static func record(
        feature: FeatureName, cause: AuthoringHaltCause, context: ActContext,
        operatorIdentity: OperatorIdentity = .none
    ) async throws -> FeatureAuthoringOutcome {
        try context.journal.append(
            .featureAuthoringHalted(name: feature.rawValue, reasonKind: cause.kind, detail: cause.detail),
            act: context.act, runID: context.runID, nightID: context.night.id
        )
        let outcome = try context.journal.recordAuthoringHalt(
            feature: feature, causeKind: cause.kind, detail: cause.detail, content: cause.description,
            nightID: context.night.id, act: context.act, runID: context.runID
        )
        if outcome.alreadyExpired { return .halted }
        let reopenKey = outcome.newlyOpened ? "feature:\(feature.rawValue):authoring-halt:\(outcome.record.id):reenter" : nil
        try await AuthoringStopBoard.post(
            feature: feature, body: cause.description, context: context, reopenKey: reopenKey,
            operatorIdentity: operatorIdentity
        ) {
            try context.journal.recordAuthoringHaltIssue(feature: feature, issueID: $0)
        }
        return .halted
    }
}
