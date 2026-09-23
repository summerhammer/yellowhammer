import Domain
import Foundation
import Journal

/// Resolves an Authoring Halt (roadmap P9.8; glossary: Authoring Halt). Clears the halt in the
/// Journal and, when the Feature Issue is known and this invocation has an Outbox and a Board,
/// moves it out of Waiting on You — or out of Blocked, when the halt had already expired — to
/// Todo (the contention state) with any Block Reason label removed, under one idempotent Outbox key.
public enum AuthoringHaltResolution {
    @discardableResult
    public static func apply(feature: FeatureName, context: ActContext) async throws -> Bool {
        guard let cleared = try context.journal.resolveAuthoringHalt(
            feature: feature, nightID: context.night.id,
            act: context.act, runID: context.runID
        ) else {
            return false
        }
        guard let issueID = cleared.record.issueID, let outbox = context.outbox, let board = context.board else {
            return true
        }
        let scope = try await BoardStateScope.resolve(using: board.provisioning)
        let change = try scope.featureContentionChange()
        let key = "feature:\(feature.rawValue):authoring-halt:cleared:\(cleared.record.id)"
        _ = try await outbox.post(OutboxWrite(
            key: key, write: .updateIssue(issue: BoardObjectID(rawValue: issueID), change: change, undo: nil)
        ))
        return true
    }
}
