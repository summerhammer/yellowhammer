import Domain
import Foundation
import Journal

/// The wait shared by `yh stop` (``EngineStop``) and `yh abort` (``AttemptAbort``): watches Attempts whose
/// abort the Operator has requested until each ends, or until the deadline passes. It writes nothing but
/// the request for a retry Attempt of a watched Card (see ``watch(_:journal:)``).
struct OperatorAbortWatch {
    let output: @Sendable (String) -> Void
    var poll: Duration = .seconds(1)
    /// How long to wait for the aborted Attempts to end.
    var wait: Duration = .seconds(60)
    /// The Operator's gesture being watched, as a noun in "started after the <gesture>": `stop` or `abort`.
    var gesture = "stop"

    /// Waits for each requested Attempt to end. A run may end one on its own and then retry the same
    /// Card: the new Attempt has no request, so a Card whose Attempt ended without `aborted` is watched
    /// for as long as it stays In Progress (it does between Attempts, through the Worktree reset), and a
    /// new Attempt of it is requested too. Attempts of other Cards are never requested here: the Project
    /// is not paused.
    func watch(_ requested: [Int64], journal: JournalStore) async throws {
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
                        "Attempt \(next.id) (\(try issueID(cardID, journal))) started after the \(gesture): " +
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

    func issueID(_ cardID: Int64?, _ journal: JournalStore) throws -> String {
        guard let cardID else { return "unknown Card" }
        return try journal.card(id: cardID).issueID
    }
}
