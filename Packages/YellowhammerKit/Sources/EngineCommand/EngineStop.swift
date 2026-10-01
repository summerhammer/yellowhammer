import Domain
import Foundation
import Journal

/// The logic of `yh stop`: records the Operator's request to abort every running Attempt of one Project
/// (spec: app/stop-the-engine-for-a-project), then optionally waits for them to end. It only records the
/// request; the Act holding the Card Leases honours it, and the next Act's Expired Lease Sweep does if that
/// Act is gone. The request is durable before anything is printed, so a closed pipe cannot lose it. It
/// pauses nothing: later Acts may still dispatch the Project's other Ready Cards.
struct EngineStop {
    let projectID: ProjectID
    let output: @Sendable (String) -> Void
    var poll: Duration = .seconds(1)
    /// How long to wait for the aborted Attempts to end; zero returns right after recording.
    var wait: Duration = .seconds(60)

    func run(journal: JournalStore) async throws {
        let requested = try journal.requestOperatorAbortOfRunningAttempts()
        guard !requested.isEmpty else {
            reportNothingToStop()
            return
        }
        let ids = requested.map(String.init).joined(separator: ", ")
        output(
            "Stopping the engine for Project \(projectID.rawValue): requested an abort of " +
                "\(requested.count) running Attempt(s): \(ids)."
        )
        guard wait > .zero else { return }
        try await OperatorAbortWatch(output: output, poll: poll, wait: wait).watch(requested, journal: journal)
    }

    /// The line printed when there is nothing to stop, also for a Project that never ran.
    func reportNothingToStop() {
        output("No Attempt is running in Project \(projectID.rawValue): nothing to stop.")
    }
}
