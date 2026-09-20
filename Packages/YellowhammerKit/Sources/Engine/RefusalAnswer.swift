import Domain
import Foundation
import Journal

/// Applies a Spec Citation that answers a Refusal (roadmap P9.8; glossary: Refusal). Moves the Refusal to
/// `answered` in the Journal and, when the Feature Issue is known and this invocation has an Outbox and a
/// Board, moves it out of Waiting on You — or out of Blocked, when the Refusal had already expired — to
/// Todo with the Block Reason label removed, under one idempotent Outbox key.
///
/// Nothing calls this yet: detecting the citation comment in the Delta Read is a later step, gated on an
/// owed probe. There is no equivalent for an Authoring Halt.
enum RefusalAnswer {
    @discardableResult
    static func apply(feature: FeatureName, citation: String, context: ActContext) async throws -> Bool {
        guard let answered = try context.journal.answerRefusal(
            feature: feature, citation: citation, nightID: context.night.id,
            act: context.act, runID: context.runID
        ) else {
            return false
        }
        guard let issueID = answered.record.issueID, let outbox = context.outbox, let board = context.board else {
            return true
        }
        let scope = try await BoardStateScope.resolve(using: board.provisioning)
        var change = scope.labels.change(objectType: "Feature", state: .todo, blockReason: nil)
        change.workflowState = try scope.id(for: .todo)
        let key = "feature:\(feature.rawValue):refusal:answered:\(answered.record.id)"
        _ = try await outbox.post(OutboxWrite(
            key: key, write: .updateIssue(issue: BoardObjectID(rawValue: issueID), change: change, undo: nil)
        ))
        return true
    }
}
