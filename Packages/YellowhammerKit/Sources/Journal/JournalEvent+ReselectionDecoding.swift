import Domain
import Foundation

// The payload and decode of the re-selection walk's own events, `featureReselected` and
// `reselectionBoundReached` (roadmap P11.6; bounds/overview), split out of
// JournalEvent+Payload.swift and JournalEvent+Decoding.swift to keep those files under the file
// length limit, as the Refusal and Authoring Halt clocks' events are split into their own files too.

extension JournalEvent {
    var featureReselectedPayload: [String: String]? {
        guard case .featureReselected(let depth, let afterRefusalOf, let reselectionsMax) = self else { return nil }
        return [
            "depth": String(depth), "after_refusal_of": afterRefusalOf,
            "reselections_max": String(reselectionsMax)
        ]
    }

    var reselectionBoundReachedPayload: [String: String]? {
        guard case .reselectionBoundReached(let depth, let reselectionsMax) = self else { return nil }
        return ["depth": String(depth), "reselections_max": String(reselectionsMax)]
    }

    static func decodeFeatureReselected(_ reader: PayloadReader) throws -> JournalEvent {
        .featureReselected(
            depth: try reader.int("depth"),
            afterRefusalOf: try reader.require("after_refusal_of"),
            reselectionsMax: try reader.int("reselections_max")
        )
    }

    static func decodeReselectionBoundReached(_ reader: PayloadReader) throws -> JournalEvent {
        .reselectionBoundReached(
            depth: try reader.int("depth"),
            reselectionsMax: try reader.int("reselections_max")
        )
    }
}
