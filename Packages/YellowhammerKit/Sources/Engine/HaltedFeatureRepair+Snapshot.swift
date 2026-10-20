import Domain
import Foundation
import Journal

extension HaltedFeatureRepair {
    /// The draft children are read again, with the Feature Card, against what was validated (roadmap P22.6): any
    /// difference accepts nothing and keeps the Operator's edits, to be validated from a fresh read, and a nil
    /// is returned. Otherwise the exact revisions admitted are recorded and described.
    static func admit(
        _ snapshot: HaltRepairSnapshot, feature: FeatureName, issue: BoardObjectID, context: ActContext
    ) async throws -> String? {
        let journal = context.journal
        let halt = try journal.liveAuthoringHalts().first { $0.id == snapshot.haltID }
        let checkpoint = try halt.flatMap { try journal.authoringHaltCheckpoint(haltID: $0.id) }
        if let halt, let checkpoint,
           let fresh = try await HaltRepairSnapshot.take(halt: halt, checkpoint: checkpoint, context: context),
           fresh.fingerprint == snapshot.fingerprint {
            try journal.recordAuthoringHaltAdmittedRevisions(haltID: halt.id, revisions: snapshot.admittedRevisions)
            let revisions = snapshot.children.map {
                "\($0.issue.rawValue)@\(ISO8601DateFormatter().string(from: $0.revision))"
            }
            return "; drafts " + revisions.joined(separator: ", ")
        }
        try journal.recordAuthoringRepairStep(
            feature: feature, step: "deferred", detail: "a draft or the Feature Card changed during validation",
            nightID: context.night.id, act: context.act, runID: context.runID
        )
        if let halt, let checkpoint {
            try await postCommentOnce(
                key: commentKey(halt: halt, seq: checkpoint.repairSeq, kind: "changed-during-validation"),
                issue: issue,
                body: """
                    Repair of Feature '\(feature)' is deferred: the Feature or one of its drafts changed while it \
                    was being validated, so nothing was accepted and your edits are untouched. It is validated \
                    again from a fresh read on a later author Act.
                    """,
                context: context
            )
        }
        return nil
    }
}
