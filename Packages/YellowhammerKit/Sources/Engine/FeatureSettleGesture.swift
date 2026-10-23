import Domain
import Foundation
import Journal

/// The injectable seam the author Act calls, once the predecessor-ancestry gate has run this Act, for
/// whatever Feature is still in flight (roadmap P10.9, P22.2; spec: morning-report/triage-the-morning).
/// Merge wins over a same-morning disposition: the gate may have already closed the Feature by merge, in
/// which case it is no longer in flight and this seam is never called for it. The real implementation is
/// ``FeatureSettleGesture``; nil skips the Board read entirely.
public protocol FeatureSettle: Sendable {
    func settle(feature: FeatureRecord, cycleID: Int64, context: ActContext) async throws
}

/// The real native-disposition seam (roadmap P22.2): reads the Feature Card's workflow state as a
/// ``FeatureDisposition`` — by workflow **type**, not by a state name — and applies it. Nothing resets
/// each day; a Feature stays in whatever disposition the Board holds.
///
/// - ``FeatureDisposition/completed`` (native Done): stop-with-salvage, closed `completion`.
/// - ``FeatureDisposition/canceled``: abandonment (`feature abandoned`).
/// - Every other disposition (backlog, ready, continuing, Waiting on You, Blocked, indeterminate): no Board
///   write and no Journal acceptance. The Feature stays in flight and the author Act's in-flight skip holds
///   the slot — a `started` state posts nothing and never resets.
///
/// Both terminal dispositions defer, by throwing ``CycleArchiveFault``, while another run holds a Card
/// Lease (``CardAutoBlock``): the Cycle is closed on a later pass, never while work may still write.
///
/// No board wired means the Board is never read at all, the same as an indeterminate disposition.
public struct FeatureSettleGesture: FeatureSettle, Sendable {
    public init() { }

    public func settle(feature: FeatureRecord, cycleID: Int64, context: ActContext) async throws {
        guard let board = context.board, context.outbox != nil else { return }

        let object = try await board.reading.issue(BoardObjectID(rawValue: feature.issueID))
        let scope = try await BoardStateScope.resolve(using: board)
        let disposition = FeatureDisposition(workflowState: object?.workflowState, scope: scope)

        // A removed Card (OQ142) is set aside: it takes no part in what is carried forward or accepted.
        let cards = try context.journal.cards(cycleID: cycleID).filter { !$0.isRemovedFromBoard }
        switch disposition {
        case .completed:
            try await applyCompleted(feature: feature, cycleID: cycleID, context: context)
        case .canceled:
            try await applyAbandoned(feature: feature, cycleID: cycleID, cards: cards, context: context)
        case .backlog, .ready, .continuing, .waitingOnYou, .blocked, .indeterminate:
            return
        }
    }

    /// Board completion (native Done): every Waiting on You Card is auto-Blocked `reply overdue`, Todo
    /// and In Progress Cards are auto-Blocked `feature completed` (``CardAutoBlock``); existing Blocked
    /// Cards keep their reasons, and every Blocked Card is detached from the Feature Issue. Counters,
    /// route exclusions, budgets and history are untouched. Every Worktree whose work is pushed is
    /// released; one holding unpushed work is kept and recorded (never discarded). The Cycle closes
    /// `completion` — a distinct route from `verification` and `merge`, claiming neither — and never sets
    /// `night.triaged_at`. The Landed Pins stay: they are the predecessor gate's tested tip until its
    /// Observed Merge is recorded.
    ///
    /// Board writes are keyed on the Cycle and posted before the Journal archives it, so a pass that dies
    /// part-way leaves the Feature in flight and is repeated whole by the next, posting nothing twice.
    private func applyCompleted(feature: FeatureRecord, cycleID: Int64, context: ActContext) async throws {
        let journal = context.journal
        guard let outbox = context.outbox else { return }

        try await CardAutoBlock.waitingOnYou(cycleID: cycleID, context: context)
        try await CardAutoBlock.releasedActive(cycleID: cycleID, reason: .featureCompleted, context: context)

        // Recomputed after the auto-Block, from Journal state.
        let cards = try journal.cards(cycleID: cycleID).filter { !$0.isRemovedFromBoard }
        let blockedCards = cards.filter { $0.state == .blocked }
        let acceptedCards = cards.filter { $0.state == .done }.map(\.issueID).sorted()
        let keptWorktrees = try await releasePushedWorktrees(featureID: feature.id, context: context)

        for card in blockedCards {
            let key = "settle:\(cycleID):complete:detach:\(card.issueID)"
            let change = BoardIssueChange(parent: .clear)
            let write = OutboxWrite(
                key: key, write: .updateIssue(issue: BoardObjectID(rawValue: card.issueID), change: change, undo: nil)
            )
            _ = try await outbox.post(write)
        }
        let comment = FeatureCompletionComment(
            carriedForward: try carriedForwardCards(
                blockedCards, cycleID: cycleID, featureIssueID: feature.issueID, journal: journal
            ),
            acceptedCards: acceptedCards, keptWorktrees: keptWorktrees
        ).body()
        let commentKey = "settle:\(cycleID):complete:comment:\(feature.issueID)"
        _ = try await outbox.post(
            OutboxWrite(
                key: commentKey, write: .createComment(issue: BoardObjectID(rawValue: feature.issueID), body: comment)
            )
        )

        let wrote = try journal.settleFeatureCompleted(
            NewFeatureCompletion(
                featureID: feature.id, cycleID: cycleID, featureIssueID: feature.issueID,
                carriedForward: blockedCards.map(\.issueID).sorted(), acceptedCards: acceptedCards,
                keptWorktrees: keptWorktrees, detachedCards: blockedCards.count
            ),
            runID: context.runID, act: context.act, nightID: context.night.id
        )
        // After the Journal write that archives the Cycle: a pin only its recorded bases still named goes now.
        if wrote {
            await LandedPinRelease(act: context.act, runID: context.runID, nightID: context.night.id).releaseBasePins(
                of: feature, repositories: context.repositories?.workingRepos ?? [], journal: journal
            )
        }
    }

    /// Releases each held Worktree whose work is pushed, and returns (sorted) the repositories whose
    /// Worktree is kept because it holds unpushed work — a completion preserves work in progress.
    private func releasePushedWorktrees(featureID: Int64, context: ActContext) async throws -> [String] {
        guard let workspace = context.workspace else { return [] }
        let held = try context.journal.worktrees(featureID: featureID).filter(\.isHeld)
        guard !held.isEmpty else { return [] }
        let allocator = WorktreeAllocator(workspace: workspace, journal: context.journal, runID: context.runID)
        var kept: [String] = []
        for worktree in held {
            guard worktree.pushedCommit != nil else {
                kept.append(worktree.repository)
                continue
            }
            _ = try await allocator.release(
                featureID: featureID, repository: worktree.repository, discardingUnpushedWork: false
            )
        }
        return kept.sorted()
    }

    /// Stop-with-salvage: every Waiting on You Card is auto-Blocked `reply overdue`, while Todo and In
    /// Progress Cards are auto-Blocked `feature abandoned` (``CardAutoBlock``). Blocked Cards are detached from the
    /// Feature Issue, every held Worktree is released — including unpushed work, which an abandon
    /// discards rather than refuses — and the Cycle is archived without `closed_by` (never a closure
    /// route; `abandoned_at` is the marker). The Feature Issue itself is never archived and its workflow
    /// state is never rewritten: it stays in the Operator's own *abandoned* state, re-enterable.
    ///
    private func applyAbandoned(
        feature: FeatureRecord, cycleID: Int64, cards: [CardRecord], context: ActContext
    ) async throws {
        let journal = context.journal
        guard feature.abandonedAt == nil else { return }

        try await CardAutoBlock.waitingOnYou(cycleID: cycleID, context: context)
        try await CardAutoBlock.releasedActive(cycleID: cycleID, reason: .featureAbandoned, context: context)

        // Recomputed after the auto-Block, from Journal state.
        let refreshedCards = try journal.cards(cycleID: cycleID).filter { !$0.isRemovedFromBoard }
        let blockedCards = refreshedCards.filter { $0.state == .blocked }
        let carriedForward = blockedCards.map(\.issueID).sorted()
        let acceptedCards = refreshedCards.filter { $0.state == .done }.map(\.issueID).sorted()

        try await releaseWorktrees(featureID: feature.id, context: context)

        let pullRequests = try journal.pullRequests(featureID: feature.id)
        let landings = try journal.landings(featureID: feature.id)
        let abandonedRepositories = pullRequests.keys.filter { landings[$0] == nil }.sorted()
        let triagedNightID = try journal.settleTriagedNightID(currentNightID: context.night.id)

        let wrote = try journal.settleFeatureReleased(
            NewFeatureRelease(
                featureID: feature.id, cycleID: cycleID, featureIssueID: feature.issueID,
                triagedNightID: triagedNightID, carriedForward: carriedForward, acceptedCards: acceptedCards,
                abandonedRepositories: abandonedRepositories
            ),
            runID: context.runID, act: context.act, nightID: context.night.id
        )
        guard wrote else { return }

        // After the Journal write, so the pins outlive nothing but a crash between the two; a pin that
        // cannot be deleted is reported in the Journal and never fails the abandon. The pins this Feature's own
        // bases kept past their Observed Merge go too: its Cycle is archived now.
        let pinRelease = LandedPinRelease(act: context.act, runID: context.runID, nightID: context.night.id)
        let workingRepos = context.repositories?.workingRepos ?? []
        await pinRelease.release(feature: feature, repositories: workingRepos, journal: journal)
        await pinRelease.releaseBasePins(of: feature, repositories: workingRepos, journal: journal)

        let computed = AbandonComputed(
            cycleID: cycleID, feature: feature, blockedCards: blockedCards, acceptedCards: acceptedCards,
            abandonedRepositories: abandonedRepositories, triagedNightID: triagedNightID
        )
        try await postAbandonBoardWrites(computed, context: context)
    }

    /// What ``applyAbandoned(feature:cycleID:cards:context:)`` computed, bundled so
    /// ``postAbandonBoardWrites(_:context:)`` stays under the parameter-count limit.
    private struct AbandonComputed {
        let cycleID: Int64
        let feature: FeatureRecord
        let blockedCards: [CardRecord]
        let acceptedCards: [String]
        let abandonedRepositories: [String]
        let triagedNightID: Int64
    }

    /// Releases every held Worktree for `featureID`, including unpushed work. A no-op on a Partial
    /// Landing — the land Act has already released every Worktree it could push.
    private func releaseWorktrees(featureID: Int64, context: ActContext) async throws {
        guard let workspace = context.workspace else { return }
        let held = try context.journal.worktrees(featureID: featureID).filter(\.isHeld)
        guard !held.isEmpty else { return }
        let allocator = WorktreeAllocator(workspace: workspace, journal: context.journal, runID: context.runID)
        for worktree in held {
            _ = try await allocator.release(
                featureID: featureID, repository: worktree.repository, discardingUnpushedWork: true
            )
        }
    }

    /// Each Blocked Card's detachment and the narrative abandon comment, keyed on the Cycle so a retry
    /// re-queues the same writes rather than duplicating them. Skipped entirely when no Outbox is wired
    /// (unreachable here in practice, since ``settle(feature:cycleID:context:)`` already required one).
    private func postAbandonBoardWrites(_ computed: AbandonComputed, context: ActContext) async throws {
        guard let outbox = context.outbox else { return }
        let journal = context.journal
        let cycleID = computed.cycleID
        let feature = computed.feature
        let blockedCards = computed.blockedCards
        let issue = BoardObjectID(rawValue: feature.issueID)

        for card in blockedCards {
            let key = "settle:\(cycleID):abandon:detach:\(card.issueID)"
            let cardIssue = BoardObjectID(rawValue: card.issueID)
            let change = BoardIssueChange(parent: .clear)
            let write = OutboxWrite(key: key, write: .updateIssue(issue: cardIssue, change: change, undo: nil))
            _ = try await outbox.post(write)
        }

        let carriedForward = try carriedForwardCards(
            blockedCards, cycleID: cycleID, featureIssueID: feature.issueID, journal: journal
        )
        let triagedNight = try journal.night(id: computed.triagedNightID)
        let comment = FeatureReleaseComment(
            carriedForward: carriedForward, acceptedCards: computed.acceptedCards,
            abandonedRepositories: computed.abandonedRepositories,
            triagedNightStart: triagedNight?.nightStart ?? context.night.nightStart
        ).body()
        let commentKey = "settle:\(cycleID):abandon:comment:\(feature.issueID)"
        _ = try await outbox.post(OutboxWrite(key: commentKey, write: .createComment(issue: issue, body: comment)))
    }

    /// Each Blocked Card paired with the Work Card it waits on (spec ruling 2026-10-22, item 8.4), ready
    /// for ``FeatureCompletionComment`` or ``FeatureReleaseComment``: nil for a Card carried forward by
    /// any other Block Reason. Shared by both terminal dispositions, since both name the same thing.
    private func carriedForwardCards(
        _ blockedCards: [CardRecord], cycleID: Int64, featureIssueID: String, journal: JournalStore
    ) throws -> [FeatureReleaseComment.CarriedForwardCard] {
        let heldBy = try HeldWorkCards.pairs(cycleID: cycleID, featureIssueID: featureIssueID, journal: journal)
        let waitsOn = Dictionary(uniqueKeysWithValues: heldBy.map {
            ($0.card.id, HeldWorkCard(issueID: $0.holder.issueID, title: $0.holder.displayTitle))
        })
        return blockedCards.map {
            FeatureReleaseComment.CarriedForwardCard(
                issueID: $0.issueID, blockReason: $0.blockReason.flatMap { BlockReason(rawValue: $0) },
                waitsOn: waitsOn[$0.id]
            )
        }
    }
}
