import Domain
import Foundation
import Journal

/// Pairs each `AuthoringDispatched` / `AuthoringRouteRejected` event with the `PromptCaptureRequested` event
/// of the same try.
///
/// A route try's ordinal restarts at 1 for every authoring walk and for every Feature's verification, so
/// (pass, ordinal) alone names several tries in one Night, and several in one Act run (the land Act verifies
/// its Features one after another). The pairing is the most recent PRECEDING capture with the same run id,
/// pass and ordinal. That is sound because every capture is appended before the dispatch it requests, and
/// so before the dispatched/rejected events that report on it (`requestPromptCapture` in `AuthoringRoute`
/// and `FeatureVerification`), and because the walks of one run are sequential, so its events are contiguous
/// in append order. An event with no such capture pairs with nothing: there is no fallback to another try.
enum PromptCapturePairing {
    /// The prompt record id each pairable event (by event id) belongs to; an unpaired event is absent.
    /// `records` must be in append order.
    static func recordIDs(in records: [JournalEventRecord]) -> [Int64: String] {
        struct Key: Hashable {
            let runID: String?
            let pass: RunPass
            let ordinal: Int
        }
        var latest: [Key: String] = [:]
        var paired: [Int64: String] = [:]
        for record in records {
            let run = record.runID?.rawValue
            switch record.event {
            case .promptCaptureRequested(let recordID, let pass, _, _, _, _, let ordinal):
                if let ordinal { latest[Key(runID: run, pass: pass, ordinal: ordinal)] = recordID }
            case .authoringDispatched(let pass, _, let ordinal, _),
                 .authoringRouteRejected(let pass, _, let ordinal, _, _):
                paired[record.id] = latest[Key(runID: run, pass: pass, ordinal: ordinal)]
            default:
                break
            }
        }
        return paired
    }
}
