import Domain
import Foundation
import Journal

/// Advances every open Refusal's and every open Authoring Halt's unanswered-Nights clock, and moves the
/// ones that expired to Blocked on the board (roadmap P9.7, P9.8; glossary: Refusal, Authoring Halt;
/// bounds/bound-unanswered-nights).
///
/// Purely Night-driven: no dates, no calendar sweep for a Night that never ran. Runs at the very top of
/// the author Act, before the in-flight check, so both clocks advance on every author Act of every Night
/// regardless of what else that Act finds to do.
enum UnansweredPositionClock {
    /// Advances both clocks by this Night, then posts one idempotent Blocked / Block Reason `reply overdue`
    /// board update for each expired Refusal and each expired halt — only when this invocation has an
    /// Outbox and a Board, and only when that row has a Feature Issue id. Without either, expiry is
    /// Journal-only: nothing throws, because a clock must advance even when this invocation cannot write
    /// to the board.
    static func run(context: ActContext, unansweredNightsMax: Int) async throws {
        _ = try context.journal.advanceRefusalClocks(
            nightID: context.night.id, unansweredNightsMax: unansweredNightsMax,
            act: context.act, runID: context.runID
        )
        _ = try context.journal.advanceAuthoringHaltClocks(
            nightID: context.night.id, unansweredNightsMax: unansweredNightsMax,
            act: context.act, runID: context.runID
        )
        // Every expired row, not only the ones this call expired: the Outbox key is idempotent, so an
        // Act killed between the expiry and its board update is completed by the next author Act. The
        // key carries the row id: a Feature answered or cleared and later expired again is Blocked again.
        var expired = try context.journal.expiredRefusals().map {
            ($0.featureName, $0.issueID, "feature:\($0.featureName):refusal:\($0.id):expired")
        }
        expired += try context.journal.expiredAuthoringHalts().map {
            ($0.featureName, $0.issueID, "feature:\($0.featureName):authoring-halt:\($0.id):expired")
        }
        guard !expired.isEmpty, let outbox = context.outbox, let board = context.board else {
            return
        }

        let scope = try await BoardStateScope.resolve(using: board.provisioning)
        for (_, issueID, key) in expired {
            guard let issueID else { continue }
            var change = scope.labels.change(cardType: .featureCard, state: .blocked, blockReason: .replyOverdue)
            change.workflowState = try scope.id(for: .blocked)
            let write = OutboxWrite(
                key: key, write: .updateIssue(issue: BoardObjectID(rawValue: issueID), change: change, undo: nil)
            )
            _ = try await outbox.post(write)
        }
    }
}
