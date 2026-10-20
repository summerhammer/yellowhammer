import Domain
import Foundation
import Journal

/// The Delta Read for one Project (spec: board-projection / read-board-changes-by-delta): what changed
/// on the board since the last read, in one request per Act, reconciled against the Journal.
///
/// Every page of both roots is read, each by its own cursor, and nothing is applied until the last one is in;
/// an observation already recorded (an issue revision, a comment) is dropped, so the overlap a cursor
/// re-reads is harmless (roadmap P22.3; see DeltaRead+Paging.swift). The read is scoped to the Project's
/// Linear project by the Board Port it was handed, and to the
/// Project's Journal by construction, so a sibling Project's Card can be neither read nor matched.
/// Yellowhammer's own comments are filtered out by identity. The Journal stays authoritative for loop
/// state: a Card the board re-stated is reported, not adopted; the one exception is Shelved, which
/// Yellowhammer reads and never writes, and which takes effect here, at the Act boundary. When the
/// board refuses for its rate budget the read degrades — nothing read is acted on, no sync point
/// moves — and the degradation is recorded as installation-wide, because the budget is the App
/// Installation's and shared by every Project on that same Board Connection.
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
    /// The Board Connection the read goes through, named on a rate-budget record. Nil for a board bound
    /// through none.
    public let installation: AppInstallationLabel?
    /// `first` on each root of the compound query. A page that overflows is followed by its root's own cursor.
    public var pageSize: Int
    /// A read that has not reached its last page after this many requests stops rather than loop: it is an
    /// incomplete sync, which moves no cursor and defers whatever depends on what it did not see.
    public var requestLimit = 40
    /// Whether an Operator re-ready (Blocked → Todo) is applied. The author and land Acts' reads set this
    /// false: they run no Card, and the author Act has no Cycle a Todo Card could run in (issue #559), so
    /// the re-ready is recorded as restated. The observation is not lost: a read that is not the build Act's
    /// leaves it pending, and the next build Act's read applies it (``ownsBuildDecisions``).
    public var acceptsReReady = true

    let clock: @Sendable () -> Date
    /// The board-side "now" captured when a read starts: the sync horizon. A cursor never moves past
    /// `horizon - syncOverlap`, so a change that arrives while the pages are being read stays eligible
    /// for the next read.
    let horizon: @Sendable () -> Date

    public init(
        journal: JournalStore,
        board: any Board,
        runID: RunID,
        act: Act? = nil,
        nightID: Int64? = nil,
        repositories: Set<String>? = nil,
        installation: AppInstallationLabel? = nil,
        pageSize: Int = 50,
        clock: @escaping @Sendable () -> Date = { Date() },
        horizon: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.journal = journal
        self.board = board
        self.runID = runID
        self.act = act
        self.nightID = nightID
        self.repositories = repositories
        self.installation = installation
        self.pageSize = pageSize
        self.clock = clock
        self.horizon = horizon
    }

    // MARK: - Reading

    // `perform()` — the independent per-root paging, the durable deduplication and the cursor — lives in
    // DeltaRead+Paging.swift, split out to keep this file under the type-length limit.

    // MARK: - Reconciling

    func reconcile(
        objects: [BoardObject], comments: [BoardComment], identity: BoardIdentity, plan: ReadPlan, requests: Int
    ) throws -> DeltaReadReport {
        var report = DeltaReadReport(since: plan.since, syncPoint: plan.syncPoint, requests: requests)

        for comment in comments {
            if comment.author.isYellowhammer || (comment.author.id != nil && comment.author.id == identity.id) {
                report.ownComments += 1
                continue
            }
            let card = try journal.card(issueID: comment.issue.rawValue)
            report.humanComments.append(HumanComment(comment: comment, card: card))
            if let card {
                try append(.humanCardComment(
                    cardID: card.id, commentID: comment.id.rawValue, commentedAt: comment.createdAt
                ))
            }
        }

        let pendingWrites = Dictionary(grouping: try journal.pendingOutboxEntries()) { $0.issueID ?? "" }
        let preservedProseHashes = try lastPreservedProseHashes()
        for object in objects {
            try recordDisplay(of: object)
            guard let card = try journal.card(issueID: object.id.rawValue) else {
                // The sole repair exception to "an object the Journal has no Card for is unknown" (roadmap P22.6):
                // a child nested beneath the exact halted Feature Card of this Project, on this Board Connection,
                // enters that halt's candidate snapshot once its parent is confirmed. It stays a draft.
                if try admitHaltDraftChild(object) {
                    report.haltDraftChildren.append(object)
                    continue
                }
                try reportUnbackedWaitingOnYou(object: object, into: &report)
                report.unknownObjects.append(object)
                continue
            }
            // A replayed revision was already reported (and its events appended) by the read that first
            // observed it: the build Act's report carries it again, but the event log does not.
            let replayed = plan.replayed.contains(object.id)
            try reportUnansweredWaitingOnYou(card: card, object: object, replayed: replayed, into: &report)
            try reconcile(
                card: card, object: object,
                inputs: CardInputs(
                    pendingWrites: pendingWrites, preservedProseHashes: preservedProseHashes, replayed: replayed
                ),
                into: &report
            )
        }

        try classifyAndRecordReplies(into: &report)

        // The observations are stored before the cursors move, in one transaction (spec: sync-boundary).
        if let record = plan.record {
            try journal.recordBoardRead(record, runID: runID, now: clock())
        }
        if plan.completes {
            try append(.deltaReadCompleted(
                objects: objects.count, comments: comments.count, ownComments: report.ownComments,
                requests: requests, since: plan.since, syncPoint: plan.syncPoint
            ))
        }
        return report
    }

    /// Admits `object` to a tracked halted Feature's candidate snapshot when it is nested beneath that exact
    /// Feature Card (roadmap P22.6); false for any other object, which stays unknown.
    private func admitHaltDraftChild(_ object: BoardObject) throws -> Bool {
        guard let parent = object.parent, object.archivedAt == nil, !object.isTrashed,
              let halt = try journal.liveAuthoringHalt(featureIssueID: parent.rawValue) else { return false }
        try journal.admitAuthoringHaltChild(
            haltID: halt.id, issueID: object.id.rawValue, title: object.title, revision: object.updatedAt
        )
        return true
    }

    /// Every object, known or not: the Feature and the Night Card are not Cards but the Pulse opens them too
    /// (issue #230) and displays readable identifiers (issue #326). Silent: no event, and the report is unchanged.
    private func recordDisplay(of object: BoardObject) throws {
        if !object.key.isEmpty {
            try journal.recordIssueIDForDisplay(
                issueID: object.id.rawValue, displayID: object.key, runID: runID, now: clock()
            )
        }
        if !object.key.isEmpty, !object.url.isEmpty {
            try journal.recordIssueLink(
                issueID: object.id.rawValue, key: object.key, url: object.url, runID: runID, now: clock()
            )
        }
    }

    /// How the board removed this Card's issue, or nil when it is on the board. A trashed issue is always
    /// removed; an archived one only while the Card is in play, or was already recorded as removed.
    static func removal(of object: BoardObject, card: CardRecord) -> CardRemoval? {
        if object.isTrashed { return .trashed }
        guard object.archivedAt != nil else { return nil }
        if let recorded = card.removedFromBoard { return recorded }
        return card.state.isInPlay ? .archived : nil
    }

    /// One known Card: removal, then Shelved either way, then a re-stated board copy, then the
    /// description. Each finding is recorded in the event log as it is made.
    private func reconcile(
        card: CardRecord,
        object: BoardObject,
        inputs: CardInputs,
        into report: inout DeltaReadReport
    ) throws {
        var card = card
        let boardState = object.workflowState

        if !object.title.isEmpty, object.title != card.title {
            // The Operator renamed the issue: the Journal's copy of the title (issue #161; spec:
            // landing/announce-a-partial-landing) is kept current so the Roll-up and the
            // partial-landing PR body name the Card by its current title.
            card = try journal.updateCardTitle(cardID: card.id, title: object.title, runID: runID, now: clock())
        }

        if let how = Self.removal(of: object, card: card) {
            // Set aside (OQ142): nothing is reconciled, restated or posted for a removed Card — the
            // Journal keeps it exactly as it stood until the board restores the issue.
            if !card.isRemovedFromBoard {
                card = try journal.markCardRemovedFromBoard(
                    cardID: card.id, how: how, runID: runID, act: act, nightID: nightID, now: clock()
                )
                try journal.abortPendingOutboxEntries(
                    issueID: card.issueID, reason: "the Card's issue is \(how.rawValue); nothing is posted to it"
                )
                report.removed.append(RemovedCard(card: card, how: how))
            }
            return
        }
        if card.isRemovedFromBoard {
            card = try journal.restoreCardToBoard(
                cardID: card.id, runID: runID, act: act, nightID: nightID, now: clock()
            )
            report.restoredToBoard.append(card)
        }

        let stateDiffers = try reconcileState(
            card: &card, boardState: boardState, pending: inputs.pendingWrites[card.issueID] ?? [],
            replayed: inputs.replayed,
            into: &report
        )

        let change = try describeManagedBlock(card: card, object: object, stateDiffers: stateDiffers, inputs: inputs)
        if let named = change.repositoryOnBoard, let reason = invariantBreakReason(card: card, named: named) {
            report.invariantBreaks.append(InvariantBreak(card: card, reason: reason))
            if !inputs.replayed {
                try append(.authoringInvariantBroken(cardID: card.id, issueID: card.issueID, reason: reason))
            }
        }
        report.cardChanges.append(change)
    }

    /// Reconciles Shelved, Operator re-ready and re-stated board copies. Returns true when the
    /// board must be restated from the Journal and no write to the issue is pending.
    private func reconcileState(
        card: inout CardRecord,
        boardState: BoardWorkflowState,
        pending: [OutboxEntry],
        replayed: Bool,
        into report: inout DeltaReadReport
    ) throws -> Bool {
        let boardSaysShelved = boardState.isShelved
        switch (card.state, boardSaysShelved) {
        case (.shelved, true):
            return false
        case (_, true):
            card = try journal.markCardShelved(
                cardID: card.id, runID: runID, act: act, nightID: nightID, now: clock()
            )
            try journal.abortPendingOutboxEntries(
                issueID: card.issueID, reason: "the Card is Shelved; nothing is posted to it"
            )
            report.shelved.append(card)
            return false
        case (.shelved, false):
            card = try journal.restoreShelvedCard(
                cardID: card.id, runID: runID, act: act, nightID: nightID, now: clock()
            )
            report.reopened.append(card)
            return false
        case (_, false):
            guard boardState.name != card.state.rawValue else { return false }
            // A write of ours still on its way to the board is not the Operator's doing; a board that holds
            // neither the state it was decided against nor its target means a human moved the issue, and the
            // write is superseded so the human's state is read as input rather than hidden behind it.
            if try supersedingStalePendingWrites(of: &card, pending: pending, boardState: boardState) { return false }
            if try reReadyIfBlocked(card: &card, boardState: boardState, into: &report) {
                return false
            }
            // The board moved the Card to a state the Journal did not write. The Journal is
            // authoritative; the board copy is reposted from it, not the other way round.
            report.restated.append(RestatedCard(card: card, boardState: boardState))
            if !replayed {
                try append(.cardRestated(
                    cardID: card.id, issueID: card.issueID, journalState: card.state, boardState: boardState.name
                ))
            }
            return true
        }
    }

    /// An unknown board object labelled Card, read in Waiting on You: the Journal has no Card behind
    /// it at all. Archived or trashed issues are not on the Operator's board and are not anomalies.
    private func reportUnbackedWaitingOnYou(object: BoardObject, into report: inout DeltaReadReport) throws {
        guard !object.isTrashed, object.archivedAt == nil else { return }
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
        card: CardRecord, object: BoardObject, replayed: Bool, into report: inout DeltaReadReport
    ) throws {
        guard card.state == .waitingOnYou, card.waitingReason == nil else { return }
        let reason = "\(object.key) is Waiting on You in the Journal with no waiting reason recorded"
        report.anomalies.append(
            WaitingOnYouAnomaly(issueID: card.issueID, key: object.key, cardID: card.id, reason: reason)
        )
        if !replayed {
            try append(.waitingOnYouUnbacked(issueID: card.issueID, cardID: card.id, reason: reason))
        }
    }

    // The Waiting on You reply classification and recording (roadmap P11.2; spec G-8) — dispatched
    // here from `reconcile` — live in DeltaRead+WaitingOnYouReplies.swift, split out to keep this file
    // under the type-length limit.

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

    // The repository line parser for the Card's Managed Block (roadmap P5.6; issue #446) lives in
    // DeltaRead+Repository.swift, split out to keep this file under the file-length limit.

    // MARK: - Events

    func append(_ event: JournalEvent) throws {
        try journal.append(event, act: act, runID: runID, nightID: nightID, now: clock())
    }
}

/// What reconciling one known Card needs beside the Card and its board copy.
struct CardInputs {
    /// The Outbox entries still pending, by the issue they address.
    var pendingWrites: [String: [OutboxEntry]]
    var preservedProseHashes: [String: String]
    /// The board copy is a revision an earlier author or land read observed and left for the build Act.
    var replayed: Bool
}

extension CardState {
    /// A Card the Operator can still act on: everything but Done and Shelved. An archived Card in one
    /// of these states was removed from the board while the Journal still had it in play.
    var isInPlay: Bool {
        switch self {
        case .todo, .inProgress, .blocked, .waitingOnYou: true
        case .done, .shelved: false
        }
    }
}
