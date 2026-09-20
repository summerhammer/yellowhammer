import Foundation

// The author Act's fault and dispatch events' payloads (roadmap P9.10, P9.11), split out of
// JournalEvent+Payload.swift (whose exhaustive switch still dispatches to them) to keep that file under
// the file length limit.

extension JournalEvent {
    var authoringFaultPayload: [String: String]? {
        switch self {
        case .featureAuthoringFailed(let name, let groupKey, let reason):
            ["name": name, "group_key": groupKey, "reason": reason]
        case .featureBreakdownRejected(let name, let reason):
            ["name": name, "reason": reason]
        case .authoringDispatched(let pass, let route, let ordinal, let fixture):
            {
                var dict = ["pass": pass.rawValue, "route": route, "ordinal": String(ordinal)]
                if let fixture {
                    dict["fixture"] = fixture
                }
                return dict
            }()
        case .featureSelectionFailed(let reason):
            ["reason": reason]
        default:
            nil
        }
    }
}
