import Domain
import Foundation
import Journal

extension FeatureSettleGesture {
    /// A tracked Feature Card in a state named `Kept in Flight` or `Abandoned` reads by its category now
    /// (the P22.2 name bridge is gone, roadmap P22.9): `started` is `continuing`, whatever the name. The
    /// Operator may still believe the name means something, so the Card is told once that it does not: a
    /// comment on the Feature Card and a `legacyBoardObserved` event the Night Card carries. The comment's
    /// Outbox key names the issue and the state, so it is posted once per pair however many Acts read it.
    /// Nothing else depends on the name.
    func noteRetiredState(of feature: FeatureRecord, object: BoardObject?, context: ActContext) async throws {
        guard let outbox = context.outbox, let state = object?.workflowState,
              LegacyBoardTaxonomy.isRetiredSettleState(state)
        else { return }
        let key = "legacy:v\(LegacyBoardMigration.version):notice:\(feature.issueID):\(state.id.rawValue)"
        guard try context.journal.outboxEntry(clientID: outbox.clientID(for: key)) == nil else { return }
        _ = try outbox.accept(OutboxWrite(
            key: key,
            write: .createComment(
                issue: BoardObjectID(rawValue: feature.issueID),
                body: "`\(state.name)`\n\n\(LegacyBoardTaxonomy.retiredStateNotice)"
            )
        ))
        try outbox.append(.legacyBoardObserved(kind: "retired-state", issueID: feature.issueID, detail: state.name))
        _ = try await outbox.deliverPending()
    }
}
