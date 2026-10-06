import Domain
import Foundation
import Journal

/// The injectable seam the author Act calls, once the predecessor-ancestry gate has run this Act, for
/// whatever Feature is still in flight (roadmap P10.9; spec: morning-report/triage-the-morning). Merge
/// wins over a same-morning release: the gate may have already closed the Feature by merge, in which
/// case it is no longer in flight and this seam is never called for it. The real implementation is
/// ``FeatureSettleGesture``; nil skips the settle read entirely.
public protocol FeatureSettle: Sendable {
    func settle(feature: FeatureRecord, cycleID: Int64, context: ActContext) async throws
    @discardableResult
    func reset(feature: FeatureRecord, cycleID: Int64, context: ActContext) async throws -> Bool
}

/// The real settle gesture (roadmap P10.9): reads the Feature Issue's workflow state as a tri-state —
/// *unsettled*, *kept in flight*, or *released* (``SettleValue``) — and applies it.
///
/// *unsettled* (including any state name the gesture does not recognise, and a value read that this
/// pass's offered set does not include) writes nothing but the ``SettleGestureComment`` stating the
/// consequence of each offered choice, keyed so it posts once per (Cycle, offered set) — the author Act
/// already skips authoring while a Feature is in flight (``AuthorAct``), so *unsettled* itself needs no
/// further Journal write here.
///
/// On a Partial Landing (``JournalStore/inFlightLandedFeature()`` non-nil), and when the Roll-up is
/// absent (Cards exist and every one is Cancelled), only *released* is offered — a *kept in flight* read there is not honoured
/// (``JournalEvent/settleValueNotHonoured(featureIssueID:value:reason:)``, treated as unsettled).
/// Otherwise both values are offered.
///
/// No board wired means the settle gesture is never read at all, the same as *unsettled*.
public struct FeatureSettleGesture: FeatureSettle, Sendable {
    public init() { }

    /// Resets a kept-in-flight Feature's workflow state on the board back to *unsettled* (``SettleValue/resetTargetState``),
    /// so the Operator is presented with the settle gesture on the subsequent morning triage (roadmap P10.9; Gate G-6).
    @discardableResult
    public func reset(feature: FeatureRecord, cycleID: Int64, context: ActContext) async throws -> Bool {
        guard let board = context.board, let outbox = context.outbox else { return false }
        return try await Self.resetSettleState(
            feature: feature, cycleID: cycleID, nightID: context.night.id, board: board, outbox: outbox
        )
    }

    /// Resets a kept-in-flight Feature's workflow state on the board back to *unsettled* (``SettleValue/resetTargetState``).
    ///
    /// Idempotent on `(cycleID, nightID)`. If the Feature Issue is not in `Kept in Flight` (e.g. already reset,
    /// released, or in another state), no write is posted.
    @discardableResult
    public static func resetSettleState(
        feature: FeatureRecord,
        cycleID: Int64,
        nightID: Int64,
        board: ActBoard,
        outbox: Outbox
    ) async throws -> Bool {
        let issue = BoardObjectID(rawValue: feature.issueID)
        guard let object = try await board.reading.issue(issue),
              let read = SettleValue(workflowStateName: object.workflowState.name),
              read.requiresDailyReset else {
            return false
        }

        let scope = try await BoardStateScope.resolve(using: board.provisioning)
        var change = scope.labels.change(cardType: .featureCard, state: SettleValue.resetTargetState, blockReason: nil)
        change.workflowState = try scope.id(for: SettleValue.resetTargetState)

        let key = "settle:\(cycleID):reset:\(nightID)"
        _ = try await outbox.post(OutboxWrite(key: key, write: .updateIssue(issue: issue, change: change, undo: nil)))
        _ = try await outbox.deliverPending()
        return true
    }

    public func settle(feature: FeatureRecord, cycleID: Int64, context: ActContext) async throws {
        guard let board = context.board, let outbox = context.outbox else { return }

        let cards = try context.journal.cards(cycleID: cycleID)
        let offered = try Self.offeredValues(cards: cards, context: context)

        let issue = BoardObjectID(rawValue: feature.issueID)
        let object = try await board.reading.issue(issue)
        let read = object.flatMap { SettleValue(workflowStateName: $0.workflowState.name) }

        guard let read else {
            try await postUnsettledComment(offered: offered, feature: feature, cycleID: cycleID, outbox: outbox)
            return
        }

        guard offered.contains(read) else {
            try context.journal.append(
                .settleValueNotHonoured(
                    featureIssueID: feature.issueID, value: read.rawValue,
                    reason: "not among this pass's offered values (\(Self.offeredKey(offered)))"
                ),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            try await postUnsettledComment(offered: offered, feature: feature, cycleID: cycleID, outbox: outbox)
            return
        }

        switch read {
        case .keptInFlight:
            try applyKeptInFlight(feature: feature, cycleID: cycleID, cards: cards, context: context)
        case .released:
            try await applyReleased(feature: feature, cycleID: cycleID, cards: cards, context: context)
        }
    }

    /// Both values, unless this is a Partial Landing or the Roll-up is absent (Cards exist and every one
    /// is Cancelled) — then only *released* is offered (glossary: Roll-up, Partial Landing).
    private static func offeredValues(cards: [CardRecord], context: ActContext) throws -> [SettleValue] {
        let allCancelled = !cards.isEmpty && cards.allSatisfy { $0.state == .cancelled }
        let landed = try context.journal.inFlightLandedFeature() != nil
        if allCancelled || landed { return [.released] }
        return [.keptInFlight, .released]
    }

    private static func offeredKey(_ offered: [SettleValue]) -> String {
        offered.map(\.rawValue).sorted().joined(separator: ", ")
    }

    /// States the consequence of each offered choice before the Operator picks one, keyed on the Cycle
    /// id and the offered set so it posts once while the Feature is running and once more when it
    /// becomes a Partial Landing (the offered set can shrink to `released` alone at that point).
    private func postUnsettledComment(
        offered: [SettleValue], feature: FeatureRecord, cycleID: Int64, outbox: Outbox
    ) async throws {
        let key = "settle:\(cycleID):unsettled:\(Self.offeredKey(offered).replacingOccurrences(of: ", ", with: "|"))"
        let issue = BoardObjectID(rawValue: feature.issueID)
        let body = SettleGestureComment(offered: offered).body()
        _ = try await outbox.post(OutboxWrite(key: key, write: .createComment(issue: issue, body: body)))
    }

    /// Records the morning's triage and the Cycle's accepted Cards. No Card or board state write: the
    /// Feature simply stays in flight, unchanged.
    private func applyKeptInFlight(
        feature: FeatureRecord, cycleID: Int64, cards: [CardRecord], context: ActContext
    ) throws {
        let acceptedCards = cards.filter { $0.state == .done }.map(\.issueID).sorted()
        let triagedNightID = try context.journal.settleTriagedNightID(currentNightID: context.night.id)
        _ = try context.journal.settleFeatureKeptInFlight(
            NewFeatureSettled(
                cycleID: cycleID, featureIssueID: feature.issueID, acceptedCards: acceptedCards,
                triagedNightID: triagedNightID
            ),
            runID: context.runID, act: context.act, nightID: context.night.id
        )
    }

    /// Stop-with-salvage: every Waiting on You Card is auto-Blocked `reply overdue`, while Todo and In
    /// Progress Cards are auto-Blocked `feature abandoned` (``CardAutoBlock``). Blocked Cards are detached from the
    /// Feature Issue, every held Worktree is released — including unpushed work, which a release
    /// discards rather than refuses — and the Cycle is archived without `closed_by` (never a closure
    /// route; `released_at` is the marker). The Feature Issue itself is never archived and its workflow
    /// state is never rewritten: it stays in the Operator's own *released* state, re-enterable.
    ///
    private func applyReleased(
        feature: FeatureRecord, cycleID: Int64, cards: [CardRecord], context: ActContext
    ) async throws {
        let journal = context.journal
        guard feature.releasedAt == nil else { return }

        try await CardAutoBlock.waitingOnYou(cycleID: cycleID, context: context)
        try await CardAutoBlock.releasedActive(cycleID: cycleID, context: context)

        // Recomputed after the auto-Block, from Journal state.
        let refreshedCards = try journal.cards(cycleID: cycleID)
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

        let computed = ReleaseComputed(
            cycleID: cycleID, feature: feature, blockedCards: blockedCards, acceptedCards: acceptedCards,
            abandonedRepositories: abandonedRepositories, triagedNightID: triagedNightID
        )
        try await postReleaseBoardWrites(computed, context: context)
    }

    /// What ``applyReleased(feature:cycleID:cards:context:)`` computed, bundled so
    /// ``postReleaseBoardWrites(_:context:)`` stays under the parameter-count limit.
    private struct ReleaseComputed {
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

    /// Each Blocked Card's detachment and the narrative release comment, keyed on the Cycle so a retry
    /// re-queues the same writes rather than duplicating them. Skipped entirely when no Outbox is wired
    /// (unreachable here in practice, since ``settle(feature:cycleID:context:)`` already required one).
    private func postReleaseBoardWrites(_ computed: ReleaseComputed, context: ActContext) async throws {
        guard let outbox = context.outbox else { return }
        let journal = context.journal
        let cycleID = computed.cycleID
        let feature = computed.feature
        let blockedCards = computed.blockedCards
        let issue = BoardObjectID(rawValue: feature.issueID)

        for card in blockedCards {
            let key = "settle:\(cycleID):release:detach:\(card.issueID)"
            let cardIssue = BoardObjectID(rawValue: card.issueID)
            let change = BoardIssueChange(parent: .clear)
            let write = OutboxWrite(key: key, write: .updateIssue(issue: cardIssue, change: change, undo: nil))
            _ = try await outbox.post(write)
        }

        let carriedForwardCards = blockedCards.map {
            FeatureReleaseComment.CarriedForwardCard(
                issueID: $0.issueID, blockReason: $0.blockReason.flatMap { BlockReason(rawValue: $0) }
            )
        }
        let triagedNight = try journal.night(id: computed.triagedNightID)
        let comment = FeatureReleaseComment(
            carriedForward: carriedForwardCards, acceptedCards: computed.acceptedCards,
            abandonedRepositories: computed.abandonedRepositories,
            triagedNightStart: triagedNight?.nightStart ?? context.night.nightStart
        ).body()
        let commentKey = "settle:\(cycleID):release:comment:\(feature.issueID)"
        _ = try await outbox.post(OutboxWrite(key: commentKey, write: .createComment(issue: issue, body: comment)))
    }
}
