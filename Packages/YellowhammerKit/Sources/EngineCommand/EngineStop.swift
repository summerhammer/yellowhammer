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
        try await watch(requested, journal: journal)
    }

    /// The line printed when there is nothing to stop, also for a Project that never ran.
    func reportNothingToStop() {
        output("No Attempt is running in Project \(projectID.rawValue): nothing to stop.")
    }

    /// Waits for each requested Attempt to end. A run may end one on its own and then retry the same
    /// Card: the new Attempt has no request, so a Card whose Attempt ended without `aborted` is watched
    /// for as long as it stays In Progress (it does between Attempts, through the Worktree reset), and a
    /// new Attempt of it is requested too. Attempts of other Cards are never requested here: the Project
    /// is not paused.
    private func watch(_ requested: [Int64], journal: JournalStore) async throws {
        var open = Set(requested)
        var cardOf: [Int64: Int64] = [:]
        for id in requested {
            cardOf[id] = try journal.attempt(id: id)?.cardID
        }
        var mayRetry: Set<Int64> = []
        let deadline = ContinuousClock.now.advanced(by: wait)
        while true {
            for id in open.sorted() {
                guard let attempt = try journal.attempt(id: id), let result = attempt.result, !attempt.isOpen
                else { continue }
                open.remove(id)
                output("Attempt \(id) (\(try issueID(cardOf[id], journal))) ended \(result).")
                if result != AttemptOutcome.aborted.rawValue, let cardID = cardOf[id] {
                    mayRetry.insert(cardID)
                }
            }
            for cardID in mayRetry.sorted() {
                if let next = try journal.attemptHistory(cardID: cardID).openAttempt, cardOf[next.id] == nil {
                    _ = try journal.requestOperatorAbort(attemptID: next.id)
                    cardOf[next.id] = cardID
                    open.insert(next.id)
                    mayRetry.remove(cardID)
                    output(
                        "Attempt \(next.id) (\(try issueID(cardID, journal))) started after the stop: " +
                            "requested its abort too."
                    )
                } else if try journal.card(id: cardID).state != .inProgress {
                    mayRetry.remove(cardID)
                }
            }
            if (open.isEmpty && mayRetry.isEmpty) || ContinuousClock.now >= deadline { break }
            try await Task.sleep(for: poll)
        }
        for id in open.sorted() {
            output(
                "Attempt \(id) (\(try issueID(cardOf[id], journal))) is still running; its abort request is " +
                    "recorded, and the Act running it, or the next Act's Expired Lease Sweep, will end it."
            )
        }
    }

    private func issueID(_ cardID: Int64?, _ journal: JournalStore) throws -> String {
        guard let cardID else { return "unknown Card" }
        return try journal.card(id: cardID).issueID
    }
}
