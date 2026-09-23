import Domain
import Foundation
import Journal
import Repositories

/// Re-validates every Card a selection tried to adopt, before the breakdown is drafted (roadmap P11.5;
/// spec: feature-authoring/author-the-cycle-and-card-dag, second story): the same provenance test the
/// Readiness Check runs at dispatch, run here at authoring time. A stale Transcription Block is a failed
/// Adoption — refused durably, outside the authoring Outbox group, so the refusal stands even if
/// authoring itself later rolls back. Untestable-and-not-stale provenance excludes a Card from this
/// Night's Adoption without refusing it — it remains a candidate for a later selection. Clean provenance
/// keeps a Card in the narrowed selection ``AuthoringTransaction`` hands to drafting.
enum AdoptionRevalidation {
    /// What re-validation found: the selection narrowed to the Cards that passed, and whether at least
    /// one Card was refused — the signal ``AuthoringTransaction`` uses to tell a genuine
    /// ``FeatureBreakdownError/noCards`` apart from one caused entirely by an Adoption refusal.
    struct Outcome {
        let selection: SelectedFeature
        let hadRefusals: Bool
    }

    static func revalidate(
        _ selection: SelectedFeature, provenance: any ProvenanceTesting, context: ActContext,
        failedAdoptionsMax: Int = 2
    ) async throws -> Outcome {
        guard !selection.adoptedCardIssueIDs.isEmpty, let repositories = context.repositories else {
            return Outcome(selection: selection, hadRefusals: false)
        }
        let journal = context.journal
        var kept: [String] = []
        var hadRefusals = false

        for issueID in selection.adoptedCardIssueIDs {
            guard let card = try journal.card(issueID: issueID) else {
                throw AuthoringTransactionError.adoptedCardUnknown(issueID: issueID)
            }
            let blocks = try journal.transcriptionBlocks(cardID: card.id).map(\.block)
            let report = await provenance.evaluate(
                blocks, projectRepositories: repositories, mainlines: context.mainlines
            )

            if report.hasDivergence {
                // The refusal's board writes need this Card's Lease. Another run holding it is not a
                // finding about the Card: it is simply not adopted tonight, and nothing is recorded as
                // a Divergence.
                if case .held(let holder) = try journal.claimCardLease(cardID: card.id, runID: context.runID) {
                    try recordNotAdopted(
                        card: card, reasons: ["the Card Lease is held by run \(holder.runID)"],
                        feature: selection.name, context: context
                    )
                    continue
                }
                hadRefusals = true
                try await refuse(
                    card: card, report: report, feature: selection.name, context: context,
                    failedAdoptionsMax: failedAdoptionsMax
                )
                continue
            }
            if !report.isAllClean {
                try recordUntestable(card: card, report: report, feature: selection.name, context: context)
                continue
            }
            kept.append(issueID)
        }

        let narrowed = SelectedFeature(
            name: selection.name, reasoning: selection.reasoning, sequence: selection.sequence,
            repositories: selection.repositories, adoptedCardIssueIDs: kept
        )
        return Outcome(selection: narrowed, hadRefusals: hadRefusals)
    }

    /// Records the durable Divergence, moves the Card to a fresh Waiting on You under `divergence`
    /// assigned to the Operator (through the board projection under the Card Lease, mirroring
    /// ``CardAutoBlock``), and renders the Managed Block's notice. The caller has already claimed the
    /// Card Lease; it is released here.
    private static func refuse(
        card: CardRecord, report: CardProvenanceReport, feature: FeatureName, context: ActContext,
        failedAdoptionsMax: Int
    ) async throws {
        let journal = context.journal
        let staleBlocks = report.results.filter(\.isDiverged).map {
            AdoptionStaleBlock(repository: $0.repository, changedPaths: $0.changedPaths)
        }
        do {
            try journal.recordAdoptionRefusal(
                cardID: card.id, nightID: context.night.id, featureName: feature.rawValue,
                staleBlocks: staleBlocks, failedAdoptionsMax: failedAdoptionsMax,
                act: context.act, runID: context.runID
            )
            try await transitionToWaitingOnYou(card: card, context: context)
        } catch {
            _ = try? journal.releaseCardLease(cardID: card.id, runID: context.runID)
            throw error
        }
        try journal.releaseCardLease(cardID: card.id, runID: context.runID)
    }

    private static func transitionToWaitingOnYou(card: CardRecord, context: ActContext) async throws {
        let journal = context.journal
        if let outbox = context.outbox, let board = context.board {
            let scope = try await BoardStateScope.resolve(using: board.provisioning)
            let projection = BoardStateProjection(journal: journal, outbox: outbox, scope: scope)
            let assignee = await context.operatorIdentity.assignee(on: board.reading)
            let current = try journal.card(id: card.id)
            let outcome = try await projection.transition(
                card: current, to: .waitingOnYou(.divergence, operator: assignee)
            )
            let updated: CardRecord
            switch outcome {
            case .unchanged(let record), .posted(let record, _), .deferred(let record, _), .failed(let record, _):
                updated = record
            }
            try await maintainManagedBlock(card: updated, journal: journal, outbox: outbox)
        } else {
            try journal.transitionCard(
                cardID: card.id, to: .waitingOnYou, waitingReason: .divergence,
                runID: context.runID, act: context.act, nightID: context.night.id
            )
        }
    }

    private static func maintainManagedBlock(card: CardRecord, journal: JournalStore, outbox: Outbox) async throws {
        let brief = ArchitecturalBrief(
            prose: try journal.architecturalBriefProse(cardID: card.id) ?? "",
            transcriptions: try journal.transcriptionBlocks(cardID: card.id).map(\.block)
        )
        let maintenance = ManagedBlockMaintenance(journal: journal, outbox: outbox)
        _ = try await maintenance.maintain(card: card, brief: brief)
    }

    /// Records why a Card's provenance could not be tested this Night, without touching a Divergence or
    /// any counter: the Card simply is not adopted, and remains a candidate for later.
    private static func recordUntestable(
        card: CardRecord, report: CardProvenanceReport, feature: FeatureName, context: ActContext
    ) throws {
        let reasons: [String] = report.results.compactMap {
            if case .untestable(let reason) = $0.verdict { return "\($0.repository): \(reason)" }
            return nil
        }
        try recordNotAdopted(card: card, reasons: reasons, feature: feature, context: context)
    }

    /// Records why a Card is not adopted this Night without being refused — no Divergence, no counter.
    private static func recordNotAdopted(
        card: CardRecord, reasons: [String], feature: FeatureName, context: ActContext
    ) throws {
        try context.journal.append(
            .adoptionUntestable(
                cardID: card.id, issueID: card.issueID, featureName: feature.rawValue, reasons: reasons
            ),
            act: context.act, runID: context.runID, nightID: context.night.id
        )
    }
}
