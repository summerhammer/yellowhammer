import Domain
import Foundation
import Journal

extension BuildActContext {
    /// The context a build Act dispatches its lanes with (roadmap P23.3): `act` is the Act's own context, whose
    /// `mainlines` keep meaning the real mainline, and ``recordedBaseMainlines`` is the Feature's `feature_base`
    /// record (``AuthoringBases/fromRecord(journal:featureID:context:)``), resolved once for the whole Act. A
    /// repository with no record keeps the real mainline there.
    static func dispatching(
        feature: FeatureRecord, cycleID: Int64, reconciliation: WorktreeReconciliation, deltaRead: DeltaReadReport?,
        act: ActContext
    ) throws -> BuildActContext {
        let recorded = try AuthoringBases.fromRecord(journal: act.journal, featureID: feature.id, context: act)
        return BuildActContext(
            act: act, feature: feature, cycleID: cycleID, reconciliation: reconciliation, deltaRead: deltaRead,
            recordedBaseMainlines: act.authoring(against: recorded).mainlines
        )
    }
}
