import Domain
import Foundation
import Journal

extension BuildActContext {
    /// The context a build Act dispatches its lanes with (roadmap P23.3): `act` is the Act's own context, whose
    /// `mainlines` keep meaning the real mainline, and ``recordedBaseMainlines`` is the Feature's `feature_base`
    /// record (``AuthoringBases/fromRecord(journal:featureID:context:git:)``), resolved once for the whole Act, with
    /// every working repository the Feature does not touch at its current `effective_base(R)` (issue #731). A
    /// touched repository with no record, or an untouched one whose base cannot be resolved, is an
    /// ``AuthoringBaseFault``, never a read of the real mainline.
    static func dispatching(
        feature: FeatureRecord, cycleID: Int64, reconciliation: WorktreeReconciliation, deltaRead: DeltaReadReport?,
        act: ActContext
    ) async throws -> BuildActContext {
        let recorded = try await AuthoringBases.fromRecord(journal: act.journal, featureID: feature.id, context: act)
        if let fault = recorded.faults.first {
            throw fault
        }
        return BuildActContext(
            act: act, feature: feature, cycleID: cycleID, reconciliation: reconciliation, deltaRead: deltaRead,
            recordedBaseMainlines: act.authoring(against: recorded).mainlines
        )
    }
}
