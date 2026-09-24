import Domain
import Foundation
import Journal

/// The single write path to the board, for one Project (spec: board-projection /
/// write-board-updates-through-the-outbox).
///
/// A write is first *accepted* — persisted in the Project's Journal under a deterministic client id —
/// and only then *delivered* through the Board Port. Acceptance survives process death, so a run that
/// dies after the board applied a write but before the Journal heard of it replays it on the next Act,
/// and the board's "conflict on insert" says it was already applied. Immediately before each write the
/// run's Lease is revalidated — the Act-scoped one, and the Card's when the write is about a Card — so
/// a stale run never reaches the board. A description is only ever written by the fenced rewrite,
/// after a pre-flight read that is never a cache.
///
/// The Outbox is scoped to the Journal it was handed, which is one Project's; it cannot address
/// another Project's entries or Linear project.
public struct Outbox: Sendable {
    public let journal: JournalStore
    public let board: any BoardWriting
    public let runID: RunID
    /// Stamped on every event the Outbox records.
    public let act: Act?
    public let nightID: Int64?
    /// How many transient failures (the board unreachable, a response unreadable) a write survives
    /// before it is recorded as permanently failed. A rate-limit refusal never counts.
    public var attemptLimit = 3

    let clock: @Sendable () -> Date
    /// Serialises deliveries: the build Act's Repo Lanes run concurrently and each posts board state
    /// through this one Outbox, and two overlapping `deliverPending` calls would both read the same
    /// pending entry and deliver it twice. Shared by every copy of this value.
    let deliveryGate = OutboxDeliveryGate()
    /// Runs after the board applied a write and before the Journal records it: the instant a crash
    /// would lose the record. Tests throw here to simulate one.
    private let interrupt: @Sendable (OutboxEntry) throws -> Void

    public init(
        journal: JournalStore,
        board: any BoardWriting,
        runID: RunID,
        act: Act? = nil,
        nightID: Int64? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(journal: journal, board: board, runID: runID, act: act, nightID: nightID, clock: clock) { _ in }
    }

    init(
        journal: JournalStore,
        board: any BoardWriting,
        runID: RunID,
        act: Act? = nil,
        nightID: Int64? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        interrupt: @escaping @Sendable (OutboxEntry) throws -> Void
    ) {
        self.journal = journal
        self.board = board
        self.runID = runID
        self.act = act
        self.nightID = nightID
        self.clock = clock
        self.interrupt = interrupt
    }

    /// The client id a key resolves to in this Project: the same key always yields the same id.
    public func clientID(for key: String) -> UUID {
        OutboxClientID.make(projectID: journal.projectID, salt: journal.outboxSalt, key: key)
    }

    // MARK: - Accepting

    /// Persists the writes in one Journal transaction, under the run's Act-scoped Lease. Nothing reaches
    /// the board here. A key that was accepted before returns its existing entry untouched.
    public func accept(_ writes: [OutboxWrite]) throws -> [OutboxEntry] {
        try journal.acceptOutbox(try writes.map { try draft($0, groupID: nil) }, runID: runID, now: clock())
    }

    public func accept(_ write: OutboxWrite) throws -> OutboxEntry {
        try accept([write])[0]
    }

    /// Persists a group that leaves either all of its writes or none of them on the board — the
    /// authoring transaction's Feature Issue, Cards and adoptions. If one write in the group fails
    /// permanently, every create the group already applied is archived and every update with an `undo`
    /// is reverted. A group interrupted by a crash is completed on replay instead.
    public func acceptGroup(_ writes: [OutboxWrite], key: String) throws -> [OutboxEntry] {
        try journal.acceptOutbox(try writes.map { try draft($0, groupID: key) }, runID: runID, now: clock())
    }

    /// Accepts one write and delivers everything pending, this write included, in accepted order.
    public func post(_ write: OutboxWrite) async throws -> OutboxDelivery {
        let entry = try accept(write)
        let report = try await deliverPending()
        if let delivery = report.deliveries.first(where: { $0.entry.id == entry.id }) {
            return delivery
        }
        // Left pending: an earlier entry stopped the run (rate limit, transport) before this one's turn.
        return OutboxDelivery(entry: entry, outcome: .deferred(.behindAnotherEntry))
    }

    /// The Journal drafts for `writes` as one group — what ``acceptGroup(_:key:)`` accepts, for a caller
    /// that must accept the group together with a Journal event of its own.
    func drafts(_ writes: [OutboxWrite], groupID: String) throws -> [OutboxDraft] {
        try writes.map { try draft($0, groupID: groupID) }
    }

    private func draft(_ write: OutboxWrite, groupID: String?) throws -> OutboxDraft {
        if case .updateIssue(_, let change, _) = write.write, change.description != nil {
            throw OutboxError.descriptionNotFenced(key: write.key)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let payload = String(data: try encoder.encode(write.write), encoding: .utf8) ?? ""
        return OutboxDraft(
            clientID: clientID(for: write.key),
            issueID: write.write.issueID?.rawValue,
            operation: write.write.operation,
            payload: payload,
            cardID: write.cardID,
            groupID: groupID
        )
    }

    // MARK: - Delivering

    /// Delivers every pending entry in accepted order, including entries a killed run left behind.
    /// Stops at a rate-limit refusal or an unreachable board, because acting on a budget that is gone
    /// does less than waiting; a Card whose Lease this run does not hold is skipped and stays pending.
    /// Throws ``OutboxError/staleRun(_:)`` the moment the run's Act-scoped Lease is found lost.
    func deliverPendingExclusively() async throws -> OutboxDeliveryReport {
        var deliveries: [OutboxDelivery] = []
        var rolledBackGroups: Set<String> = []

        for entry in try journal.pendingOutboxEntries() {
            if let groupID = entry.groupID, rolledBackGroups.contains(groupID) { continue }

            let delivery = try await deliver(entry)
            deliveries.append(delivery)

            switch delivery.outcome {
            case .failed(let reason):
                if let groupID = entry.groupID {
                    deliveries += try await rollBack(groupID: groupID, reason: reason)
                    rolledBackGroups.insert(groupID)
                }
            case .deferred(.rateLimited), .deferred(.transient):
                return OutboxDeliveryReport(deliveries: deliveries)
            case .applied, .alreadyApplied, .aborted, .deferred:
                continue
            }
        }
        return OutboxDeliveryReport(deliveries: deliveries)
    }

    /// One entry: Lease check, the board call, then the record — in that order, always.
    func deliver(_ entry: OutboxEntry) async throws -> OutboxDelivery {
        do {
            try journal.revalidateOutboxLeases(for: entry, runID: runID, now: clock())
        } catch let error as JournalError {
            switch error {
            case .cardLeaseLost:
                let deferral = OutboxDelivery.Deferral.cardLeaseNotHeld(String(describing: error))
                return OutboxDelivery(entry: entry, outcome: .deferred(deferral))
            case .actLeaseLost:
                throw OutboxError.staleRun(error)
            default:
                throw error
            }
        }

        let write: BoardWrite
        do {
            write = try JSONDecoder().decode(BoardWrite.self, from: Data(entry.payload.utf8))
        } catch {
            return try fail(entry, reason: "the Journal's payload for this write could not be read")
        }

        do {
            let outcome = try await perform(write, for: entry)
            try interrupt(entry)
            return try await record(outcome, for: entry, write: write)
        } catch let error as BoardError {
            return try refused(entry, write: write, error: error)
        } catch OutboxError.parentNotApplied(let entryID, let parentKey) {
            let broken = OutboxError.parentNotApplied(entryID: entryID, parentKey: parentKey)
            return try fail(entry, reason: broken.description)
        }
    }

    /// What the board did, before the Journal is told.
    enum Performed {
        case created(BoardCreateReceipt)
        case updated
        case fenced(ManagedBlockFence.Replacement, renderedHash: String)
        case unfenced(ManagedBlockFence.Failure)
    }

    private func perform(_ write: BoardWrite, for entry: OutboxEntry) async throws -> Performed {
        switch write {
        case .createIssue(var draft, let parentKey):
            if let parentKey {
                draft.parent = try parentID(forKey: parentKey, of: entry)
            }
            return .created(try await board.createIssue(draft, clientID: entry.clientID))
        case .createComment(let issue, let body):
            return .created(try await board.createComment(on: issue, body: body, clientID: entry.clientID))
        case .attachLink(let issue, let url, let title):
            return .created(try await board.attachLink(to: issue, url: url, title: title, clientID: entry.clientID))
        case .rewriteManagedBlock(let issue, let rendered):
            return try await performManagedBlock(issue: issue, rendered: rendered)
        case .updateManagedBlockLine(let issue, let prefix, let line):
            return try await performManagedBlock(issue: issue, rendered: line, replacingPrefix: prefix)
        case .updateIssue(let issue, let change, _):
            _ = try await board.updateIssue(issue, change)
            return .updated
        case .archiveIssue(let issue):
            try await board.archiveIssue(issue)
            return .updated
        case .adoptIssue(let issue, let parentKey, _):
            let parent = try parentID(forKey: parentKey, of: entry)
            _ = try await board.updateIssue(issue, BoardIssueChange(parent: .set(parent)))
            return .updated
        }
    }

    /// The created id of an earlier entry in this Project's Outbox, for a Card nested under a Feature
    /// Issue accepted in the same group. Entries deliver in accepted order, so the parent is applied
    /// first or the group is broken.
    private func parentID(forKey parentKey: String, of entry: OutboxEntry) throws -> BoardObjectID {
        let parent = try journal.outboxEntry(clientID: clientID(for: parentKey))
        guard let parent, parent.state == .applied, let id = parent.result else {
            throw OutboxError.parentNotApplied(entryID: entry.id, parentKey: parentKey)
        }
        return BoardObjectID(rawValue: id)
    }

    private func record(
        _ performed: Performed, for entry: OutboxEntry, write: BoardWrite
    ) async throws -> OutboxDelivery {
        let now = clock()
        switch performed {
        case .created(let receipt):
            let applied = try journal.markOutboxApplied(id: entry.id, result: receipt.id.rawValue, now: now)
            switch receipt {
            case .created(let id):
                return OutboxDelivery(entry: applied, outcome: .applied(id))
            case .alreadyApplied(let id):
                return OutboxDelivery(entry: applied, outcome: .alreadyApplied(id))
            }
        case .updated:
            let applied = try journal.markOutboxApplied(id: entry.id, result: nil, now: now)
            return OutboxDelivery(entry: applied, outcome: .applied(nil))
        case .fenced(let replacement, let renderedHash):
            guard let issue = write.issueID else { throw OutboxError.payloadUnreadable(entryID: entry.id) }
            let applied = try journal.markOutboxApplied(id: entry.id, result: nil, now: now)
            try journal.recordManagedBlockPosted(issueID: issue.rawValue, hash: renderedHash, now: now)
            try append(.managedBlockWritten(
                issueID: issue.rawValue, preservedProseHash: replacement.preservedProseHash, renderedHash: renderedHash
            ))
            return OutboxDelivery(entry: applied, outcome: .applied(nil))
        case .unfenced(let failure):
            guard let issue = write.issueID else { throw OutboxError.payloadUnreadable(entryID: entry.id) }
            let reason = "Managed Block delimiters broken: \(failure)"
            let aborted = try journal.markOutboxAborted(id: entry.id, reason: reason, now: now)
            try append(.managedBlockDelimiterBroken(issueID: issue.rawValue))
            // The Operator is told on the issue itself, through the Outbox like every other write, under a
            // key derived from the aborted entry so a repeated abort of the same write posts one comment.
            let diagnostic = try accept(OutboxWrite(
                key: "diagnostic:managed-block:\(entry.clientID.uuidString.lowercased())",
                write: .createComment(issue: issue, body: Self.diagnosticComment(for: failure)),
                cardID: entry.cardID
            ))
            if diagnostic.state == .pending {
                _ = try await deliver(diagnostic)
            }
            return OutboxDelivery(entry: aborted, outcome: .aborted(reason: reason))
        }
    }

    private func refused(_ entry: OutboxEntry, write: BoardWrite, error: BoardError) throws -> OutboxDelivery {
        switch error {
        case .rateLimited(let retryAfter, _):
            // The budget is the identity's, shared by every Project on the board tonight: named as
            // workspace-wide, never as this Project's own excess. The entry stays pending, untouched.
            try append(.rateBudgetExhausted(
                degradation: "board write \(write.operation) deferred; \(String(describing: error))"
            ))
            let deferral = OutboxDelivery.Deferral.rateLimited(retryAfter: retryAfter)
            return OutboxDelivery(entry: entry, outcome: .deferred(deferral))
        case .unreachable, .unreadableResponse:
            // The board may or may not have applied it. A create is safe to re-send under its client id,
            // and an update re-sends the same content, so the entry stays pending for another attempt.
            let reason = String(describing: error)
            let attempted = try journal.recordOutboxAttemptFailure(id: entry.id, error: reason)
            if attempted.attemptCount >= attemptLimit {
                return try fail(attempted, reason: "\(reason) (after \(attempted.attemptCount) attempts)")
            }
            return OutboxDelivery(entry: attempted, outcome: .deferred(.transient(reason)))
        case .notAuthenticated, .refused, .scopeNotFound:
            return try fail(entry, reason: String(describing: error))
        }
    }

    /// A permanent failure: recorded in the event log so the Night Summary can say so.
    private func fail(_ entry: OutboxEntry, reason: String) throws -> OutboxDelivery {
        let failed = try journal.markOutboxFailed(id: entry.id, error: reason, now: clock())
        try append(.boardWriteFailed(
            clientID: entry.clientID, operation: entry.operation, issueID: entry.issueID, reason: reason
        ))
        return OutboxDelivery(entry: failed, outcome: .failed(reason: reason))
    }

    // MARK: - Events

    func append(_ event: JournalEvent) throws {
        try journal.append(event, act: act, runID: runID, nightID: nightID, now: clock())
    }

    static func diagnosticComment(for failure: ManagedBlockFence.Failure) -> String {
        """
        Yellowhammer could not update this issue's Managed Block: \(failure). The description was left \
        untouched. Restore the `\(ManagedBlockFence.start)` and `\(ManagedBlockFence.end)` delimiters, \
        on their own lines with the block between them, and updates resume on the next Act.
        """
    }
}
