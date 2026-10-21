import Domain
import Foundation
import Journal

extension BuildActContext {
    /// The context a build Act dispatches its lanes with (roadmap P23.3): `act` is the Act's own context, whose
    /// `mainlines` keep meaning the real mainline, and ``recordedBaseMainlines`` is the Feature's `feature_base`
    /// record (``AuthoringBases/fromRecord(journal:featureID:context:)``), resolved once for the whole Act. A
    /// touched repository with no record is an ``AuthoringBaseFault``, never a read of the real mainline.
    static func dispatching(
        feature: FeatureRecord, cycleID: Int64, reconciliation: WorktreeReconciliation, deltaRead: DeltaReadReport?,
        act: ActContext
    ) throws -> BuildActContext {
        let recorded = try AuthoringBases.fromRecord(journal: act.journal, featureID: feature.id, context: act)
        if let fault = recorded.faults.first {
            throw fault
        }
        return BuildActContext(
            act: act, feature: feature, cycleID: cycleID, reconciliation: reconciliation, deltaRead: deltaRead,
            recordedBaseMainlines: act.authoring(against: recorded).mainlines
        )
    }
}
