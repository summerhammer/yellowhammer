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
    /// The worker commit the Check judged; `nil` for an event written before it was recorded.
    public let judgedCommit: String?
    public let occurredAt: Date
}

extension CheckRunRecord {
    /// The run `record` is, or `nil` when the event is not a `checkRan`.
    public init?(_ record: JournalEventRecord) {
        guard case .checkRan(_, _, let attemptID, let result, let exitStatus, let output, let judgedCommit) =
            record.event
        else {
            return nil
        }
        self.init(
            eventID: record.id,
            attemptID: attemptID,
            result: result,
            exitStatus: exitStatus,
            output: output,
            judgedCommit: judgedCommit,
            occurredAt: record.occurredAt
        )
    }
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

            let checkRuns = try Self.checkRuns(db, cardID: card.id)

            return CardAccount(card: card, history: history, checkRuns: checkRuns)
        }
    }

    /// Every `checkRan` event for one Card, in append order.
    public func checkRuns(cardID: Int64) throws -> [CheckRunRecord] {
        try read { db in try Self.checkRuns(db, cardID: cardID) }
    }

    private static func checkRuns(_ db: Database, cardID: Int64) throws -> [CheckRunRecord] {
        try events(db, ofType: .checkRan).compactMap { record in
            guard case .checkRan(let recordCardID, _, _, _, _, _, _) = record.event, recordCardID == cardID else {
                return nil
            }
            return CheckRunRecord(record)
        }
    }
}
