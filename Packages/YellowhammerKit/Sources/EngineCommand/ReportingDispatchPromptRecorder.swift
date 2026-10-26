import Config
import Domain
import Foundation

/// An EngineCommand prompt recorder that wraps a `DispatchPromptRecording` and logs a line via `ActLog`
/// when capture is unavailable.
public struct ReportingDispatchPromptRecorder: DispatchPromptRecording, Sendable {
    public let store: any DispatchPromptRecording

    public init(store: any DispatchPromptRecording) {
        self.store = store
    }

    public func capture(_ record: DispatchPromptRecord) -> DispatchPromptCapture {
        let result = store.capture(record)
        if case .unavailable(let cause) = result {
            ActLog.writeToStandardError(
                "prompt capture unavailable for \(record.provenance.family.rawValue) dispatch \(record.id): \(cause)"
            )
        }
        return result
    }

    public func markLaunch(_ launch: DispatchLaunch, of record: DispatchPromptRecord) -> Bool {
        store.markLaunch(launch, of: record)
    }
}
