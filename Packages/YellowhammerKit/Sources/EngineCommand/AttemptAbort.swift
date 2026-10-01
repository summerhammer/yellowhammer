import Domain
import Foundation
import Journal

/// The logic of `yh abort`: records the Operator's request to abort one running Attempt of one Project
/// (spec: app/abort-a-running-attempt), then optionally waits for it to end. Like ``EngineStop`` it only
/// records the request: the Act holding the Card Lease honours it, and the next Act's Expired Lease Sweep
/// does if that Act is gone. It kills nothing, writes no loop state and takes no Act Lease. The request is
/// durable before anything is printed, so a closed pipe, or the Operator quitting the app mid-abort,
/// cannot change the outcome. It requests no other Card's Attempt.
struct AttemptAbort {
    let projectID: ProjectID
    let attemptID: Int64
    let output: @Sendable (String) -> Void
    var poll: Duration = .seconds(1)
    /// How long to wait for the aborted Attempt to end; zero returns right after recording.
    var wait: Duration = .seconds(60)

    func run(journal: JournalStore) async throws {
        let requested: Bool
        do {
            requested = try journal.requestOperatorAbort(attemptID: attemptID)
        } catch JournalError.attemptUnknown {
            throw AttemptAbortError.unknownAttempt(attemptID: attemptID, projectID: projectID)
        }
        let watch = OperatorAbortWatch(output: output, poll: poll, wait: wait, gesture: "abort")
        let issueID = try watch.issueID(try journal.attempt(id: attemptID)?.cardID, journal)
        guard requested else {
            let result = try journal.attempt(id: attemptID)?.result ?? "unknown"
            output("Attempt \(attemptID) (\(issueID)) already ended \(result): nothing to abort.")
            return
        }
        output(
            "Aborting Attempt \(attemptID) (\(issueID)) in Project \(projectID.rawValue): requested its abort."
        )
        guard wait > .zero else { return }
        try await watch.watch([attemptID], journal: journal)
    }

    /// The line printed when the Project has no Journal, so there is no Attempt to abort.
    func reportNothingToAbort() {
        output("Project \(projectID.rawValue) has no Journal: nothing to abort.")
    }
}

/// An `yh abort` refusal the Operator can read.
enum AttemptAbortError: Error, LocalizedError, Equatable {
    case unknownAttempt(attemptID: Int64, projectID: ProjectID)

    var errorDescription: String? {
        switch self {
        case .unknownAttempt(let attemptID, let projectID):
            "Project \(projectID.rawValue) has no Attempt \(attemptID): nothing was requested."
        }
    }
}
