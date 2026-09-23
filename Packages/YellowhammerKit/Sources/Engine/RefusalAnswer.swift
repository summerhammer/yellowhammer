import Domain
import Foundation
import Journal

/// Applies a Spec Citation that answers a Refusal (roadmap P9.8; glossary: Refusal). Moves the Refusal to
/// `answered` in the Journal and, when the Feature Issue is known and this invocation has an Outbox and a
/// Board, moves it out of Waiting on You — or out of Blocked, when the Refusal had already expired — to
/// Todo (the contention state) with the Block Reason label removed, under one idempotent Outbox key.
///
/// Resolving an Authoring Halt follows the equivalent flow via ``AuthoringHaltResolution``.
public enum RefusalAnswer {
    @discardableResult
    public static func apply(feature: FeatureName, citation: String, context: ActContext) async throws -> Bool {
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
        let change = try scope.featureContentionChange()
        let key = "feature:\(feature.rawValue):refusal:answered:\(answered.record.id)"
        _ = try await outbox.post(OutboxWrite(
            key: key, write: .updateIssue(issue: BoardObjectID(rawValue: issueID), change: change, undo: nil)
        ))
        return true
    }
}
