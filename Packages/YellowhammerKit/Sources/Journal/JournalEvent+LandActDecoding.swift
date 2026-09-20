import Domain
import Foundation

// The land Act's own event's decode helper, split out of JournalEvent+Decoding.swift (whose
// exhaustive switch still dispatches to it) to keep that file under the file length limit.

extension JournalEvent {
    static func decodeLandStep(_ reader: PayloadReader) throws -> JournalEvent {
        .landStep(
            step: try reader.landStep("step"),
            repository: reader.payload?["repository"],
            outcome: try reader.landStepOutcome("outcome"),
            detail: reader.payload?["detail"]
        )
    }
}
