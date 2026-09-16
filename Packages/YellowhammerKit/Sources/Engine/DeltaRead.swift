import Domain
import Foundation
import Journal

/// The Delta Read for one Project (spec: board-projection / read-board-changes-by-delta): what changed
/// on the board since the last read, in one request per Act, reconciled against the Journal.
///
/// The read is scoped to the Project's Linear project by the Board Port it was handed, and to the
/// Project's Journal by construction, so a sibling Project's Card can be neither read nor matched.
/// Yellowhammer's own comments are filtered out by identity. The Journal stays authoritative for loop
/// state: a Card the board re-stated is reported, not adopted; the one exception is Cancelled, which
/// Yellowhammer reads and never writes, and which takes effect here, at the Act boundary. When the
/// board refuses for its rate budget the read degrades — nothing read is acted on, no sync point
/// moves — and the degradation is recorded as workspace-wide, because the budget is the identity's
/// and shared by every Project on the board tonight.
public struct DeltaRead: Sendable {
    public let journal: JournalStore
    public let board: any Board
    public let runID: RunID
    /// Stamped on every event the read records.
    public let act: Act?
    public let nightID: Int64?
    /// The names of the Project's Repos, so a Card whose board copy names a repository outside the
    /// Project is reported as an invariant break. Nil skips that check.
    public let repositories: Set<String>?
    /// `first` on each root of the compound query. A page that overflows is followed by its cursor.
    public var pageSize: Int
    /// A read that has not reached its last page after this many requests stops rather than loop.
    public var requestLimit = 40

    let clock: @Sendable () -> Date

    public init(
        journal: JournalStore,
        board: any Board,
        runID: RunID,
        act: Act? = nil,
        nightID: Int64? = nil,
        repositories: Set<String>? = nil,
        pageSize: Int = 50,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.journal = journal
        self.board = board
        self.runID = runID
        self.act = act
        self.nightID = nightID
        self.repositories = repositories
        self.pageSize = pageSize
        self.clock = clock
    }

    // MARK: - Reading

    /// Reads every page since the recorded sync point, then reconciles. Nothing is applied to the
    /// Journal until the last page is in, so a refusal half-way leaves no partial reconciliation.
    public func perform() async throws -> DeltaReadOutcome {
        let since = try journal.boardSyncPoint()?.lastSync

        var objects: [BoardObject] = []
        var comments: [BoardComment] = []
        var identity: BoardIdentity?
        var objectCursor: BoardCursor?
        var commentCursor: BoardCursor?
        var requests = 0

        repeat {
            if requests >= requestLimit {
                throw DeltaReadError.tooManyPages(requests: requests)
            }
            let delta: BoardDelta
            do {
                delta = try await board.deltaRead(
                    since: since, objectsAfter: objectCursor, commentsAfter: commentCursor, pageSize: pageSize
                )
            } catch BoardError.rateLimited(let retryAfter, _) {
                return try degrade(requests: requests + 1, retryAfter: retryAfter)
            } catch {
                throw DeltaReadError.boardUnavailable(error)
            }
            requests += 1
            identity = delta.identity
            objects += delta.updatedObjects
            comments += delta.newComments
            objectCursor = delta.nextObjectCursor
            commentCursor = delta.nextCommentCursor
        } while objectCursor != nil || commentCursor != nil

        guard let identity else { throw DeltaReadError.tooManyPages(requests: requests) }
        let report = try reconcile(
            objects: objects, comments: comments, identity: identity, since: since, requests: requests
        )
        return .read(report)
    }

    private func degrade(requests: Int, retryAfter: Duration?) throws -> DeltaReadOutcome {
        var reason = "the Delta Read was refused for the rate budget after \(requests) request(s); "
            + "nothing read this Act is acted on and the sync point is unchanged"
        if let retryAfter {
            reason += "; retry after \(retryAfter)"
        }
        try append(.rateBudgetExhausted(degradation: reason))
        return .degraded(reason: reason)
    }

    // MARK: - Reconciling

    private func reconcile(
        objects: [BoardObject], comments: [BoardComment], identity: BoardIdentity, since: Date?, requests: Int
    ) throws -> DeltaReadReport {
        let syncPoint = Self.syncPoint(objects: objects, comments: comments, since: since)
        var report = DeltaReadReport(since: since, syncPoint: syncPoint, requests: requests)

        for comment in comments {
            if comment.author.isYellowhammer || (comment.author.id != nil && comment.author.id == identity.id) {
                report.ownComments += 1
                continue
            }
            let card = try journal.card(issueID: comment.issue.rawValue)
            report.humanComments.append(HumanComment(comment: comment, card: card))
        }

        let pendingWrites = Set(try journal.pendingOutboxEntries().compactMap(\.issueID))
        let preservedProseHashes = try lastPreservedProseHashes()
        for object in objects {
            guard let card = try journal.card(issueID: object.id.rawValue) else {
                try reportUnbackedWaitingOnYou(object: object, into: &report)
                report.unknownObjects.append(object)
                continue
            }
            try reportUnansweredWaitingOnYou(card: card, object: object, into: &report)
            try reconcile(card: card, object: object, pendingWrites: pendingWrites,
                          preservedProseHashes: preservedProseHashes, into: &report)
        }

        if let syncPoint, syncPoint != since {
            try journal.recordBoardSync(lastSync: syncPoint, runID: runID, now: clock())
        }
        try append(.deltaReadCompleted(
            objects: objects.count, comments: comments.count, ownComments: report.ownComments,
            requests: requests, since: since, syncPoint: syncPoint
        ))
        return report
    }

    /// One known Card: removal, then Cancelled either way, then a re-stated board copy, then the
    /// description. Each finding is recorded in the event log as it is made.
    private func reconcile(
        card: CardRecord,
        object: BoardObject,
        pendingWrites: Set<String>,
        preservedProseHashes: [String: String],
        into report: inout DeltaReadReport
    ) throws {
        var card = card
        let boardState = object.workflowState

        if object.isTrashed || (object.archivedAt != nil && card.state.isInPlay) {
            let how: RemovedCard.How = object.isTrashed ? .trashed : .archived
            report.removed.append(RemovedCard(card: card, how: how))
            try append(.cardRemovedFromBoard(cardID: card.id, issueID: card.issueID, how: how.rawValue))
        }

        let stateDiffers = try reconcileState(
            card: &card, boardState: boardState, pendingWrites: pendingWrites, into: &report
        )

        var change = CardChange(
            card: card, object: object, stateDiffers: stateDiffers, managedBlockEdited: nil, proseEdited: nil,
            delimitersBroken: nil, repositoryOnBoard: nil
        )
        switch ManagedBlockFence.parts(of: object.description) {
        case .failure(let failure):
            change.delimitersBroken = failure
        case .success(let parts):
            if let posted = try journal.managedBlockLastPostedHash(issueID: card.issueID) {
                change.managedBlockEdited = parts.blockHash != posted
            }
            if let preserved = preservedProseHashes[card.issueID] {
                change.proseEdited = parts.preservedProseHash != preserved
            }
            change.repositoryOnBoard = Self.repository(inBlock: parts.block)
        }
        if let named = change.repositoryOnBoard, let reason = invariantBreakReason(card: card, named: named) {
            report.invariantBreaks.append(InvariantBreak(card: card, reason: reason))
            try append(.authoringInvariantBroken(cardID: card.id, issueID: card.issueID, reason: reason))
        }
        report.cardChanges.append(change)
    }

    /// Cancelled either way, or a re-stated board copy. Returns true when the board's state is one the
    /// Journal did not write and no write to the issue is pending.
    private func reconcileState(
        card: inout CardRecord,
        boardState: BoardWorkflowState,
        pendingWrites: Set<String>,
        into report: inout DeltaReadReport
    ) throws -> Bool {
        let boardSaysCancelled = boardState.name == CardState.cancelled.rawValue
        switch (card.state, boardSaysCancelled) {
        case (.cancelled, true):
            return false
        case (_, true):
            card = try journal.markCardCancelled(
                cardID: card.id, runID: runID, act: act, nightID: nightID, now: clock()
            )
            report.cancelled.append(card)
            return false
        case (.cancelled, false):
            card = try journal.restoreCancelledCard(
                cardID: card.id, runID: runID, act: act, nightID: nightID, now: clock()
            )
            report.reopened.append(card)
            return false
        case (_, false):
            guard boardState.name != card.state.rawValue, !pendingWrites.contains(card.issueID) else { return false }
            // The board moved the Card to a state the Journal did not write. The Journal is
            // authoritative; the board copy is reposted from it, not the other way round.
            report.restated.append(RestatedCard(card: card, boardState: boardState))
            try append(.cardRestated(
                cardID: card.id, issueID: card.issueID, journalState: card.state, boardState: boardState.name
            ))
            return true
        }
    }

    /// An unknown board object labelled Card, read in Waiting on You: the Journal has no Card behind
    /// it at all.
    private func reportUnbackedWaitingOnYou(object: BoardObject, into report: inout DeltaReadReport) throws {
        guard object.workflowState.name == CardState.waitingOnYou.rawValue else { return }
        guard object.labels.contains(where: { $0.lowercased() == "card" }) else { return }
        let reason = "\(object.key) was read in Waiting on You with no Journal record behind it"
        report.anomalies.append(
            WaitingOnYouAnomaly(issueID: object.id.rawValue, key: object.key, cardID: nil, reason: reason)
        )
        try append(.waitingOnYouUnbacked(issueID: object.id.rawValue, cardID: nil, reason: reason))
    }

    /// A known Card whose Journal state is Waiting on You with no waiting reason recorded: the Journal
    /// record that is supposed to back the state is itself incomplete.
    private func reportUnansweredWaitingOnYou(
        card: CardRecord, object: BoardObject, into report: inout DeltaReadReport
    ) throws {
        guard card.state == .waitingOnYou, card.waitingReason == nil else { return }
        let reason = "\(object.key) is Waiting on You in the Journal with no waiting reason recorded"
        report.anomalies.append(
            WaitingOnYouAnomaly(issueID: card.issueID, key: object.key, cardID: card.id, reason: reason)
        )
        try append(.waitingOnYouUnbacked(issueID: card.issueID, cardID: card.id, reason: reason))
    }

    private func invariantBreakReason(card: CardRecord, named: String) -> String? {
        if named != card.repository {
            return "the Card's board copy names repository '\(named)', but the Journal records '\(card.repository)'; "
                + "a Card moved to a different repository is not the work that was authored"
        }
        if let repositories, !repositories.contains(named) {
            return "the Card's board copy names repository '\(named)', which is not a Repo of this Project"
        }
        return nil
    }

    /// The hash of the prose each issue's last Managed Block write preserved, from the audit events.
    private func lastPreservedProseHashes() throws -> [String: String] {
        var hashes: [String: String] = [:]
        for record in try journal.events(ofType: .managedBlockWritten) {
            if case .managedBlockWritten(let issueID, let preservedProseHash, _) = record.event {
                hashes[issueID] = preservedProseHash
            }
        }
        return hashes
    }

    /// The latest board timestamp among what was read, or `since` unchanged when nothing was. Never the
    /// wall clock: the board's own timestamps are the only ones its `updatedAt > $lastSync` compares to.
    static func syncPoint(objects: [BoardObject], comments: [BoardComment], since: Date?) -> Date? {
        let latest = (objects.map(\.updatedAt) + comments.map(\.createdAt)).max()
        switch (latest, since) {
        case (let latest?, let since?):
            return max(latest, since)
        case (let latest?, nil):
            return latest
        case (nil, let since):
            return since
        }
    }

    /// The repository a rendered Managed Block names on its `Repository:` line — the line the Card's
    /// block renders (roadmap P5.6) as `**Repository:** \`name\``. Bold and backticks are optional, so
    /// an Operator who retyped the line is still read. Nil when the block has no such line.
    static func repository(inBlock block: String) -> String? {
        for line in block.split(whereSeparator: \.isNewline) {
            var text = Substring(line.trimmingCharacters(in: .whitespaces))
            if text.hasPrefix("- ") || text.hasPrefix("* ") { text = text.dropFirst(2) }
            text = text.drop(while: { $0 == "*" || $0 == "_" })
            guard text.lowercased().hasPrefix("repository") else { continue }
            text = text.dropFirst("repository".count)
            text = text.drop(while: { $0 == "*" || $0 == "_" || $0 == " " })
            guard text.first == ":" else { continue }
            text = text.dropFirst().drop(while: { $0 == "*" || $0 == "_" || $0 == " " || $0 == "`" })
            let name = text.prefix(while: { !$0.isWhitespace && $0 != "`" && $0 != "*" })
            return name.isEmpty ? nil : String(name)
        }
        return nil
    }

    // MARK: - Events

    private func append(_ event: JournalEvent) throws {
        try journal.append(event, act: act, runID: runID, nightID: nightID, now: clock())
    }
}

extension CardState {
    /// A Card the Operator can still act on: everything but Done and Cancelled. An archived Card in one
    /// of these states was removed from the board while the Journal still had it in play.
    var isInPlay: Bool {
        switch self {
        case .todo, .inProgress, .blocked, .waitingOnYou: true
        case .done, .cancelled: false
        }
    }
}
