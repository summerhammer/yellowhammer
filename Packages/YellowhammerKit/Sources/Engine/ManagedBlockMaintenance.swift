import Domain
import Foundation
import Journal

/// Maintains a Card's Managed Block: renders from the Journal, hashes, and conditionally posts.
public struct ManagedBlockMaintenance: Sendable {
    public let journal: JournalStore
    public let outbox: Outbox
    public let labels: DispositionLabels?  // nil → labels not maintained

    public init(journal: JournalStore, outbox: Outbox, labels: DispositionLabels? = nil) {
        self.journal = journal
        self.outbox = outbox
        self.labels = labels
    }

    public enum Outcome: Equatable, Sendable {
        case notMaintained(NotMaintained)
        case skipped(hash: String)  // rendered hash == last posted hash
        case posted(hash: String, block: OutboxDelivery, labels: OutboxDelivery?)
    }

    public enum NotMaintained: Equatable, Sendable {
        case shelved
        /// The Card's issue is trashed, or archived while the Card was in play (OQ142).
        case removedFromBoard
    }

    /// Renders the Card's block from the Journal and hashes the rendered output. Compares the hash to the
    /// last hash the Outbox recorded when a fenced rewrite was applied.
    ///
    /// When the hash matches, returns `.skipped` without touching the Outbox or board.
    ///
    /// The hash is that of the full rendering, and keys both writes. The block write carries the whole
    /// compaction ladder: delivery writes the first rung that fits the description budget.
    ///
    /// When the hash differs, accepts two OutboxWrites keyed on the rendered hash — one for the block
    /// rewrite, and one (when labels != nil) for the label change — and calls `deliverPending()`.
    /// Both deliveries are returned. The Outbox records the hash when the rewrite is applied.
    ///
    /// Keying both writes on the rendered hash makes replay safe and makes the label write skip
    /// together with the block: the block renders the state and block reason, so an unchanged block
    /// means an unchanged disposition.
    ///
    /// When the Card is Shelved, renders nothing and reads nothing from the board. Instead, aborts
    /// every pending outbox entry for this issue and returns `.notMaintained(.shelved)`. A removed Card
    /// (trashed, or archived while in play; OQ142) is treated the same way, returning
    /// `.notMaintained(.removedFromBoard)`: nothing is posted to it.
    public func maintain(card: CardRecord, brief: ArchitecturalBrief) async throws -> Outcome {
        let first = try await maintainOnce(card: card, brief: brief, keySuffix: "")
        // The rewrite imported a human's edit the Journal had not seen (``Outbox/importFreshInput``), so the
        // rendering it carried is stale: render once more from the Journal as it now stands and post that.
        guard case .posted(_, let block, _) = first, case .superseded = block.outcome else { return first }
        let current = try journal.card(id: card.id)
        let refreshed = ArchitecturalBrief(
            prose: try journal.architecturalBriefProse(cardID: card.id) ?? "",
            transcriptions: try journal.transcriptionBlocks(cardID: card.id).map(\.block)
        )
        return try await maintainOnce(card: current, brief: refreshed, keySuffix: ":imported:\(block.entry.id)")
    }

    private func maintainOnce(card: CardRecord, brief: ArchitecturalBrief, keySuffix: String) async throws -> Outcome {
        // Shelved: abort pending entries and return early
        if card.state == .shelved {
            try journal.abortPendingOutboxEntries(
                issueID: card.issueID, reason: "the Card is Shelved; nothing is posted to it"
            )
            return .notMaintained(.shelved)
        }
        if card.isRemovedFromBoard {
            try journal.abortPendingOutboxEntries(
                issueID: card.issueID, reason: "the Card's issue was removed from the board; nothing is posted to it"
            )
            return .notMaintained(.removedFromBoard)
        }

        let renderings = try renderManagedBlock(card: card, brief: brief)
        let hash = ManagedBlockFence.sha256(renderings[0])

        // Check if unchanged. The write may have gone out as any rung of the compaction ladder, so the last
        // posted hash is compared with every rendering's: a compacted post is not re-posted on every pass.
        if let lastHash = try journal.managedBlockLastPostedHash(issueID: card.issueID),
           renderings.contains(where: { ManagedBlockFence.sha256($0) == lastHash }) {
            return .skipped(hash: hash)
        }

        // Accept the block write
        let blockKey = "block:\(card.issueID):\(hash)\(keySuffix)"
        let issueID = BoardObjectID(rawValue: card.issueID)
        let blockWrite = renderings.count == 1
            ? BoardWrite.rewriteManagedBlock(issue: issueID, rendered: renderings[0])
            : BoardWrite.rewriteManagedBlockCompacting(issue: issueID, renderings: renderings)
        let blockOutboxWrite = OutboxWrite(key: blockKey, write: blockWrite, cardID: card.id)

        let blockDelivery = try await outbox.post(blockOutboxWrite)
        // Superseded by an import: the labels follow the rendering that replaces it.
        if case .superseded = blockDelivery.outcome {
            return .posted(hash: hash, block: blockDelivery, labels: nil)
        }

        var labelDelivery: OutboxDelivery?

        // Accept the labels write (if labels are being maintained)
        if let labels = labels {
            let blockReasonEnum = card.blockReason.flatMap { BlockReason(rawValue: $0) }
            let labelChange = labels.change(for: card.state, blockReason: blockReasonEnum)

            let labelKey = "labels:\(card.issueID):\(hash)"
            let labelWrite = BoardWrite.updateIssue(
                issue: BoardObjectID(rawValue: card.issueID),
                change: labelChange,
                undo: nil
            )
            let labelOutboxWrite = OutboxWrite(key: labelKey, write: labelWrite, cardID: card.id)

            labelDelivery = try await outbox.post(labelOutboxWrite)
        }

        return .posted(hash: hash, block: blockDelivery, labels: labelDelivery)
    }

    /// Builds the Card's Managed Block from the Journal and renders it: the full rendering first, then each
    /// more compacted one (``CardManagedBlock/renderings()``).
    private func renderManagedBlock(card: CardRecord, brief: ArchitecturalBrief) throws -> [String] {
        let history = try journal.attemptHistory(cardID: card.id)
        let checkRuns = try journal.checkRuns(cardID: card.id)
        let attempts = history.attempts.enumerated().map { index, attempt in
            AttemptAccount(
                ordinal: index + 1, record: attempt, checkRuns: checkRuns.filter { $0.attemptID == attempt.id }
            )
        }
        let doDClauses = try journal.clauses(issueID: card.issueID).map { DoDClause($0) }
        let laneLength = try journal.repoLaneLength(cycleID: card.cycleID, repository: card.repository)
        let scope = try journal.declaredScope(cardID: card.id)
        // This maintenance holds no configuration, so `attempts_per_work_card` never reaches the Managed
        // Block's rendering (roadmap P8.7): the consumption account renders without a Bound to compare it
        // to, rather than plumbing configuration through a layer built to hold none.
        let consumption = attempts.isEmpty ? nil : history.consumption(inEpoch: card.budgetEpoch)

        let managedBlock = CardManagedBlock(
            kind: card.kind,
            repository: card.repository,
            scope: scope,
            state: card.state,
            blockReason: card.blockReason,
            lanePosition: card.authoredOrder,
            laneLength: laneLength,
            brief: brief,
            definitionOfDone: doDClauses,
            attempts: attempts,
            attemptConsumption: consumption,
            failureRecurrence: try failureRecurrence(card: card),
            adoptionRefusalNotice: try adoptionRefusalNotice(card: card),
            unadoptedStanding: try unadoptedStanding(card: card),
            authoringDefectNotice: try authoringDefectNotice(card: card)
        )
        return managedBlock.renderings()
    }

    /// The Card's un-adopted standing (roadmap P12.1), `asOf` the latest recorded Night — read from the
    /// same `JournalStore.unadoptedCards(asOf:)` derivation the Night Summary's standing line uses, so
    /// the two figures can never disagree. Nil for every Card the derivation does not return.
    private func unadoptedStanding(card: CardRecord) throws -> UnadoptedStanding? {
        guard let latest = try journal.nights(mode: .real).last else { return nil }
        guard let match = try journal.unadoptedCards(asOf: latest.nightStart).first(where: { $0.card.id == card.id })
        else {
            return nil
        }
        return UnadoptedStanding(closedFeatureIssueID: match.closedFeatureIssueID, elapsedNights: match.elapsedNights)
    }

    /// The Card's latest adoption refusal, rendered only while it is Waiting on You under `divergence`
    /// and that refusal is still the reason (roadmap P11.5): a later readiness Divergence, or leaving
    /// Waiting on You for any reason, clears it.
    private func adoptionRefusalNotice(card: CardRecord) throws -> AdoptionRefusalNotice? {
        guard card.state == .waitingOnYou, card.waitingReason == .divergence,
              let refusal = try journal.latestDivergenceIsAdoptionRefusal(cardID: card.id)
        else {
            return nil
        }
        return AdoptionRefusalNotice(featureName: refusal.featureName, staleBlocks: refusal.staleBlocks)
    }

    /// The recurrence to show on the Card: only while it is Blocked under `failure recurrence`, naming the
    /// failure cause the Journal recorded last against it (roadmap P8.8; OQ127). Keyed on the Block
    /// Reason, not on the cause having recurred: the count never resets, so a Card Blocked later on
    /// another reason must not carry the line.
    private func failureRecurrence(card: CardRecord) throws -> FailureRecurrence? {
        guard card.state == .blocked, card.blockReason == BlockReason.failureRecurrence.rawValue,
              let last = try journal.lastRecordedFailureCause(cardID: card.id) else {
            return nil
        }
        return FailureRecurrence(cause: last.summary, nights: last.recurrenceCount)
    }

    /// The reported authoring-invariant violation to show on the Card: only while it is Blocked under
    /// `authoring defect` (Missing Upstream Ruling 2026-10-15, OQ175), reading the durable Journal event.
    private func authoringDefectNotice(card: CardRecord) throws -> AuthoringDefectNotice? {
        guard card.state == .blocked, card.blockReason == BlockReason.authoringDefect.rawValue,
              let reason = try journal.lastAuthoringInvariantViolationReason(cardID: card.id)
        else {
            return nil
        }
        return AuthoringDefectNotice(detail: AuthoringDefectNotice.extractDetail(from: reason))
    }
}
