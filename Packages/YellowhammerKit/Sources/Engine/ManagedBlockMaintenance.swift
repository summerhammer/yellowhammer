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
        case cancelled
    }

    /// Renders the Card's block from the Journal and hashes the rendered output. Compares the hash to the
    /// last hash the Outbox recorded when a fenced rewrite was applied.
    ///
    /// When the hash matches, returns `.skipped` without touching the Outbox or board.
    ///
    /// When the hash differs, accepts two OutboxWrites keyed on the rendered hash — one for the block
    /// rewrite, and one (when labels != nil) for the label change — and calls `deliverPending()`.
    /// Both deliveries are returned. The Outbox records the hash when the rewrite is applied.
    ///
    /// Keying both writes on the rendered hash makes replay safe and makes the label write skip
    /// together with the block: the block renders the state and block reason, so an unchanged block
    /// means an unchanged disposition.
    ///
    /// When the Card is Cancelled, renders nothing and reads nothing from the board. Instead, aborts
    /// every pending outbox entry for this issue and returns `.notMaintained(.cancelled)`.
    public func maintain(card: CardRecord, brief: ArchitecturalBrief) async throws -> Outcome {
        // Cancelled: abort pending entries and return early
        if card.state == .cancelled {
            try journal.abortPendingOutboxEntries(
                issueID: card.issueID, reason: "the Card is Cancelled; nothing is posted to it"
            )
            return .notMaintained(.cancelled)
        }

        let rendered = try renderManagedBlock(card: card, brief: brief)
        let hash = ManagedBlockFence.sha256(rendered)

        // Check if unchanged
        if let lastHash = try journal.managedBlockLastPostedHash(issueID: card.issueID), lastHash == hash {
            return .skipped(hash: hash)
        }

        // Accept the block write
        let blockKey = "block:\(card.issueID):\(hash)"
        let issueID = BoardObjectID(rawValue: card.issueID)
        let blockWrite = BoardWrite.rewriteManagedBlock(issue: issueID, rendered: rendered)
        let blockOutboxWrite = OutboxWrite(key: blockKey, write: blockWrite, cardID: card.id)

        let blockDelivery = try await outbox.post(blockOutboxWrite)

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

    /// Builds the Card's Managed Block from the Journal and renders it.
    private func renderManagedBlock(card: CardRecord, brief: ArchitecturalBrief) throws -> String {
        let history = try journal.attemptHistory(cardID: card.id)
        let attempts = history.attempts.enumerated().map { AttemptAccount(ordinal: $0.offset + 1, record: $0.element) }
        let doDClauses = try journal.clauses(issueID: card.issueID).map { DoDClause($0) }
        let laneLength = try journal.repoLaneLength(cycleID: card.cycleID, repository: card.repository)
        let scope = try journal.declaredScope(cardID: card.id)
        // This maintenance holds no configuration, so `attempts_per_card` never reaches the Managed
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
            triagePromotion: try triagePromotion(card: card),
            adoptionRefusalNotice: try adoptionRefusalNotice(card: card),
            unadoptedStanding: try unadoptedStanding(card: card)
        )
        return managedBlock.render()
    }

    /// The Card's un-adopted standing (roadmap P12.1), `asOf` the latest recorded Night — read from the
    /// same `JournalStore.unadoptedCards(asOf:)` derivation the Night Summary's standing line uses, so
    /// the two figures can never disagree. Nil for every Card the derivation does not return.
    private func unadoptedStanding(card: CardRecord) throws -> UnadoptedStanding? {
        guard let latest = try journal.nights().last else { return nil }
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

    /// The promotion to show on the Card: only while it is Blocked, and only when the failure cause the
    /// Journal recorded last against it had recurred across separate Nights (roadmap P8.8).
    private func triagePromotion(card: CardRecord) throws -> TriagePromotion? {
        guard card.state == .blocked, let last = try journal.lastRecordedFailureCause(cardID: card.id),
              last.hasRecurred else {
            return nil
        }
        return TriagePromotion(cause: last.summary, nights: last.recurrenceCount)
    }
}
