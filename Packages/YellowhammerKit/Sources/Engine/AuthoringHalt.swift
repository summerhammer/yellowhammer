import Domain
import Foundation
import Journal

/// Records an Authoring Halt durably before any board write, then — only when this invocation has an
/// Outbox and a Board — puts the Feature in Waiting on You naming the cause. Allocates no Worktree,
/// dispatches nothing and records no Attempt.
///
/// Shared by ``FeatureSelection`` (the seam and repository-determination halts, roadmap P9.3) and
/// ``AuthoringTransaction`` (the unreadable contract, P9.6, and a breakdown that consumes its own Feature's work,
/// ``ContractOverlapCheck``). Not the thin-spec finding: that is a
/// Refusal, recorded by ``RefusalRecording``. The two share only ``AuthoringStopBoard``. A halt never
/// touches a Refusal or any consecutive count.
///
/// Once a halt has expired, a repeat writes nothing to the board at all: the Feature Issue stays
/// Blocked, no re-create into Waiting on You and no repeated comment. Repeated authoring faults append
/// the forced run's result even after expiry, keeping the existing state.
enum AuthoringHalt {
    /// `selection` is the accepted selection the halt arose after, kept in the halt's checkpoint so a repaired
    /// Feature resumes without selecting again (roadmap P22.5); nil when the selector halted before choosing one.
    static func record(
        feature: FeatureName, cause: AuthoringHaltCause, selection: SelectedFeature? = nil, context: ActContext
    ) async throws -> FeatureAuthoringOutcome {
        try context.journal.append(
            .featureAuthoringHalted(name: feature.rawValue, reasonKind: cause.kind, detail: cause.detail),
            act: context.act, runID: context.runID, nightID: context.night.id
        )
        let outcome = try context.journal.recordAuthoringHalt(
            feature: feature, causeKind: cause.kind, detail: cause.detail, content: cause.description,
            selection: selection, nightID: context.night.id, act: context.act, runID: context.runID
        )
        let repeatedFault: Bool
        if case .authoringRepeatedlyFaulted = cause { repeatedFault = true } else { repeatedFault = false }
        if outcome.alreadyExpired, !repeatedFault { return .halted }
        let reopenKey = outcome.newlyOpened && !repeatedFault
            ? "feature:\(feature.rawValue):authoring-halt:\(outcome.record.id):reenter"
            : nil
        try await AuthoringStopBoard.post(
            feature: feature, body: cause.description, context: context, reopenKey: reopenKey,
            commentSuffix: repeatedFault ? context.runID.rawValue : nil,
            recordIssue: { try context.journal.recordAuthoringHaltIssue(feature: feature, issueID: $0) },
            // The Feature Card is Waiting on You after this post, so that is the state every later halt-related
            // write is decided against (roadmap P22.5) until the board is read again.
            recordState: { state in
                guard let halt = try context.journal.authoringHalts(feature: feature).last else { return }
                try context.journal.recordAuthoringHaltObservation(
                    haltID: halt.id, stateID: state.rawValue, category: .started, revision: Date()
                )
            }
        )
        return .halted
    }
}
