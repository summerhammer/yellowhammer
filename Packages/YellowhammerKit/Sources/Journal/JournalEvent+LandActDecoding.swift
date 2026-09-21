import Domain
import Foundation

// The land Act's own event's decode helper, split out of JournalEvent+Decoding.swift (whose
// exhaustive switch still dispatches to it) to keep that file under the file length limit.

extension JournalEvent {
    static func decodeLandAct(_ type: JournalEventType, _ reader: PayloadReader) throws -> JournalEvent {
        switch type {
        case .featureVerified:
            .featureVerified(
                cycleID: try reader.int64("cycle_id"), met: try reader.int("met"),
                unmet: try reader.int("unmet"), unresolved: try reader.int("unresolved")
            )
        default:
            try decodeLandStep(reader)
        }
    }

    /// The `featureVerified` event's payload: counts only.
    var featureVerifiedPayload: [String: String]? {
        guard case .featureVerified(let cycleID, let met, let unmet, let unresolved) = self else { return nil }
        return [
            "cycle_id": String(cycleID), "met": String(met), "unmet": String(unmet), "unresolved": String(unresolved)
        ]
    }

    static func decodeLandStep(_ reader: PayloadReader) throws -> JournalEvent {
        .landStep(
            step: try reader.landStep("step"),
            repository: reader.payload?["repository"],
            outcome: try reader.landStepOutcome("outcome"),
            detail: reader.payload?["detail"]
        )
    }
}
