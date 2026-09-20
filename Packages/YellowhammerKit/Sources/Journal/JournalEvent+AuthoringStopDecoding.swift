import Domain
import Foundation

// The Authoring Halt's events and the Refusal's answer (P9.8): their payload encoding and decode helpers,
// split out of JournalEvent+Payload.swift and JournalEvent+Decoding.swift (whose exhaustive switches still
// dispatch to them) to keep those files under the file length limit. None of the halt events carries a
// consecutive count: only a Refusal counts.

extension JournalEvent {
    /// The shared `refusalOpened` / `refusalRepeated` payload; the two keys added in P9.8 are written
    /// only when they carry something, so a payload without them stays byte-identical to an old one.
    static func refusalPayload(
        _ feature: String, _ consecutiveRefusals: Int, _ clauses: String, _ depth: Int
    ) -> [String: String] {
        var dict = ["feature": feature, "consecutive_refusals": String(consecutiveRefusals)]
        if !clauses.isEmpty {
            dict["uncitable_clauses"] = clauses
        }
        if depth != 0 {
            dict["reselection_depth"] = String(depth)
        }
        return dict
    }

    var authoringStopPayload: [String: String]? {
        switch self {
        case .refusalAnswered(let feature, let citation, let from):
            return ["feature": feature, "citation": citation, "from": from]
        case .authoringHaltOpened(let feature, let causeKind, let detail),
            .authoringHaltRepeated(let feature, let causeKind, let detail):
            var dict = ["feature": feature, "cause_kind": causeKind]
            if let detail {
                dict["detail"] = detail
            }
            return dict
        case .authoringHaltExpired(let feature, let issueID, let unansweredNights, let bound):
            var dict = ["feature": feature, "unanswered_nights": String(unansweredNights), "bound": String(bound)]
            if let issueID {
                dict["issue_id"] = issueID
            }
            return dict
        case .authoringHaltCleared(let feature):
            return ["feature": feature]
        default:
            return nil
        }
    }

    static func decodeAuthoringStop(_ type: JournalEventType, _ reader: PayloadReader) throws -> JournalEvent {
        let feature = try reader.require("feature")
        switch type {
        case .refusalAnswered:
            return .refusalAnswered(
                feature: feature, citation: try reader.require("citation"), from: try reader.require("from")
            )
        case .authoringHaltOpened:
            return .authoringHaltOpened(
                feature: feature, causeKind: try reader.require("cause_kind"), detail: reader.payload?["detail"]
            )
        case .authoringHaltRepeated:
            return .authoringHaltRepeated(
                feature: feature, causeKind: try reader.require("cause_kind"), detail: reader.payload?["detail"]
            )
        case .authoringHaltExpired:
            return .authoringHaltExpired(
                feature: feature, issueID: reader.payload?["issue_id"],
                unansweredNights: try reader.int("unanswered_nights"), bound: try reader.int("bound")
            )
        default:
            return .authoringHaltCleared(feature: feature)
        }
    }
}
