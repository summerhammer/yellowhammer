import Domain
import Foundation
import Journal

/// Advances every open Refusal's unanswered-Nights clock, and moves the ones that expired to Blocked
/// on the board (roadmap P9.7; glossary: Refusal; bounds/bound-unanswered-nights).
///
/// Purely Night-driven: no dates, no calendar sweep for a Night that never ran. Runs at the very top of
/// the author Act, before the in-flight check, so a Refusal's clock advances on every author Act of
/// every Night regardless of what else that Act finds to do.
enum RefusalLifecycle {
    /// Advances every open Refusal's clock by this Night, then posts one idempotent Blocked / Block
    /// Reason `unanswered` board update for each expired Refusal — only when this
    /// invocation has an Outbox and a Board, and only when that Refusal has a Feature Issue id. Without
    /// either, expiry is Journal-only: nothing throws, because a Refusal's clock must advance even when
    /// this invocation cannot write to the board.
    static func run(context: ActContext, unansweredNightsMax: Int) async throws {
        _ = try context.journal.advanceRefusalClocks(
            nightID: context.night.id, unansweredNightsMax: unansweredNightsMax,
            act: context.act, runID: context.runID
        )
        // Every expired Refusal, not only the ones this call expired: the Outbox key is idempotent, so
        // an Act killed between the expiry and its board update is completed by the next author Act.
        let expired = try context.journal.expiredRefusals()
        guard !expired.isEmpty, let outbox = context.outbox, let board = context.board else {
            return
        }

        let scope = try await BoardStateScope.resolve(using: board.provisioning)
        for refusal in expired {
            guard let issueID = refusal.issueID else { continue }
            var change = scope.labels.change(objectType: "Feature", state: .blocked, blockReason: .unanswered)
            change.workflowState = try scope.id(for: .blocked)

            let key = "feature:\(refusal.featureName):refusal:expired"
            let write = OutboxWrite(
                key: key, write: .updateIssue(issue: BoardObjectID(rawValue: issueID), change: change, undo: nil)
            )
            _ = try await outbox.post(write)
        }
    }
}
