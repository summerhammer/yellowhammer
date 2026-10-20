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
            ExpiredPosition(issueID: $0.issueID, key: "feature:\($0.featureName):refusal:\($0.id):expired")
        }
        for halt in try context.journal.expiredAuthoringHalts() {
            // The Feature Card's last observed state is the condition the Blocked write is decided against. A
            // Feature Card the Operator moved to Todo to ask for a repair — or one already completed or canceled —
            // is theirs: expiry is recorded in the Journal and the checkpoint kept, but Blocked is never written
            // over it (roadmap P22.5; spec: bounds/overview, overdue clock).
            let checkpoint = try context.journal.authoringHaltCheckpoint(haltID: halt.id)
            if let category = checkpoint?.observedCategory, category != .started { continue }
            expired.append(ExpiredPosition(
                issueID: halt.issueID, key: "feature:\(halt.featureName):authoring-halt:\(halt.id):expired",
                expectedState: checkpoint?.observedStateID.map(BoardObjectID.init(rawValue:)), haltID: halt.id
            ))
        }
        guard !expired.isEmpty, let outbox = context.outbox, let board = context.board else {
            return
        }

        let scope = try await BoardStateScope.resolve(using: board.provisioning)
        for position in expired {
            guard let issueID = position.issueID else { continue }
            var change = scope.labels.change(cardType: .featureCard, state: .blocked, blockReason: .replyOverdue)
            change.workflowState = try scope.id(for: .blocked)
            let write = OutboxWrite(
                key: position.key,
                write: .updateIssue(issue: BoardObjectID(rawValue: issueID), change: change, undo: nil),
                expectedState: position.expectedState
            )
            _ = try await outbox.post(write)
            if let haltID = position.haltID {
                try context.journal.recordAuthoringHaltObservation(
                    haltID: haltID, stateID: try scope.id(for: .blocked).rawValue, category: .started,
                    revision: Date()
                )
            }
        }
    }

    /// One expired position's board update: the issue, its idempotent Outbox key, and — for an Authoring Halt —
    /// the Feature Card state Yellowhammer last observed there, which the write is decided against.
    private struct ExpiredPosition {
        var issueID: String?
        var key: String
        var expectedState: BoardObjectID?
        var haltID: Int64?

        init(issueID: String?, key: String, expectedState: BoardObjectID? = nil, haltID: Int64? = nil) {
            self.issueID = issueID
            self.key = key
            self.expectedState = expectedState
            self.haltID = haltID
        }
    }
}
