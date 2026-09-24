import Domain
import Foundation
import GRDB

/// One engine-run Check's outcome, as the `checkRan` event recorded it. The full Check output lives
/// only here: a failed Check's Round also carries it in `requested_changes`, but a passed or
/// declared-none Check exists only as this event.
public struct CheckRunRecord: Equatable, Sendable {
    public let eventID: Int64
    public let attemptID: Int64
    public let result: CheckRunResult
    public let exitStatus: Int32?
    public let output: String?
    public let occurredAt: Date
}

/// The whole read-only account of one Card the app shows behind a Card (roadmap P14.5): the Card
/// itself, its Attempt and Round history, and every Check run against it, in append order.
public struct CardAccount: Equatable, Sendable {
    public let card: CardRecord
    public let history: AttemptHistory
    /// Every `checkRan` event for this Card, in append order.
    public let checkRuns: [CheckRunRecord]

    /// This Card's Check runs for one Attempt, in append order.
    public func checkRuns(attemptID: Int64) -> [CheckRunRecord] {
        checkRuns.filter { $0.attemptID == attemptID }
    }
}

extension JournalStore {
    /// The app's read (roadmap P14.5): one Card's whole account — the Card, its Attempt/Round
    /// history, and its Check runs — as a single consistent snapshot. Every table is read inside one
    /// `read` transaction, so a concurrent Act writing the same Journal never leaves the account
    /// straddling two states. Reads only; never gates or mutates anything. `nil` when no Card has
    /// `issueID`.
    public func cardAccount(issueID: String) throws -> CardAccount? {
        try read { db in
            guard let card = try Self.card(db, issueID: issueID) else {
                return nil
            }

            let history = try Self.attemptHistory(db, cardID: card.id)

            let checkRuns: [CheckRunRecord] = try Self.events(db, ofType: .checkRan).compactMap { record in
                guard
                    case .checkRan(let cardID, _, let attemptID, let result, let exitStatus, let output) = record.event,
                    cardID == card.id
                else {
                    return nil
                }
                return CheckRunRecord(
                    eventID: record.id,
                    attemptID: attemptID,
                    result: result,
                    exitStatus: exitStatus,
                    output: output,
                    occurredAt: record.occurredAt
                )
            }

            return CardAccount(card: card, history: history, checkRuns: checkRuns)
        }
    }
}
