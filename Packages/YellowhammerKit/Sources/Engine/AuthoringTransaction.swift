import Domain
import Foundation
import Journal

/// What stopped the authoring transaction before it could accept anything.
public enum AuthoringTransactionError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The invocation has no Outbox or no Board: authoring cannot run silently without one.
    case noBoard
    /// An adopted Card has no row (or no Feature) in the Journal.
    case adoptedCardUnknown(issueID: String)
    /// An applied Outbox entry the plan names has no created id.
    case appliedEntryWithoutID(key: String)

    public var description: String {
        switch self {
        case .noBoard:
            "Authoring needs an Outbox and a Board, and this invocation has none."
        case .adoptedCardUnknown(let issueID):
            "The Journal has no Card row for adopted issue \(issueID)."
        case .appliedEntryWithoutID(let key):
            "The Outbox entry \(key) is applied but recorded no created id."
        }
    }
}

/// The authoring transaction (roadmap P9.4; spec: feature-authoring/author-the-cycle-and-card-dag):
/// creates a selected Feature's Feature Issue, its Cards as native sub-issues of it, and its adoptions,
/// as ONE Outbox group, then writes the Feature, Cycle and Card rows only once the board holds all of it.
///
/// Atomic on both sides. On the board, a permanent failure rolls the group back (created issues are
/// archived, adopted Cards get their previous parent back). In the Journal, the plan is recorded in the
/// same transaction that accepts the group, and the rows are written in one transaction after delivery —
/// so a crash leaves either a plan a later Act resumes, or a board nobody has to guess at. Nothing here
/// creates a Linear milestone or a Linear cycle: the Cycle is Yellowhammer's own, projected as `parentId`.
public struct AuthoringTransaction: SelectedFeatureAuthoring {
    public let drafting: any FeatureBreakdownDrafting
    /// Resolves a drafted clause's Spec Citation before it is accepted into the Outbox (roadmap P9.5;
    /// spec: feature-authoring/author-citable-definitions-of-done, first story).
    public let citations: any CitationResolving
    /// Transcribes a drafted contract from another repository's merged mainline before it is accepted
    /// into the Outbox (roadmap P9.6; spec: feature-authoring/author-an-architectural-brief).
    public let transcribing: any ContractTranscribing
    /// Re-validates every Card the selection tries to adopt, before the breakdown is drafted (roadmap
    /// P11.5; spec: feature-authoring/author-the-cycle-and-card-dag, second story) — the same test the
    /// Readiness Check runs at dispatch.
    public let provenance: any ProvenanceTesting
    /// The refusal-drift promotion Bound (roadmap P11.6; bounds/overview): how many
    /// consecutive Refusals a Feature may carry before it is promoted to a standing item. Defaults to
    /// the glossary's own default of 3.
    public let consecutiveRefusalsMax: Int
    /// The Divergence promotion Bound (roadmap P11.6; bounds/overview): how many
    /// consecutive failed Adoptions a Card may carry before it is promoted to a standing item. Defaults
    /// to the glossary's own default of 2.
    public let failedAdoptionsMax: Int

    public init(
        drafting: any FeatureBreakdownDrafting, citations: any CitationResolving,
        transcribing: any ContractTranscribing, provenance: any ProvenanceTesting,
        consecutiveRefusalsMax: Int = 3, failedAdoptionsMax: Int = 2
    ) {
        self.drafting = drafting
        self.citations = citations
        self.transcribing = transcribing
        self.provenance = provenance
        self.consecutiveRefusalsMax = consecutiveRefusalsMax
        self.failedAdoptionsMax = failedAdoptionsMax
    }

    public func author(
        _ selection: SelectedFeature, reselectionDepth: Int = 0, context: ActContext
    ) async throws -> FeatureAuthoringOutcome {
        guard let outbox = context.outbox, let board = context.board else {
            throw AuthoringTransactionError.noBoard
        }
        // Every Card the selection tries to adopt is re-validated before the breakdown is drafted
        // (roadmap P11.5), so the Feature is sized without any Card whose Adoption is refused.
        let revalidated = try await AdoptionRevalidation.revalidate(
            selection, provenance: provenance, context: context, failedAdoptionsMax: failedAdoptionsMax
        )
        let selection = revalidated.selection
        guard let breakdown = try await draft(selection, context: context) else {
            return .authoringRolledBack
        }
        if let rejection = try await validateBreakdown(
            breakdown, for: selection, revalidated: revalidated, context: context
        ) {
            return rejection
        }

        // Every drafted clause's citation is resolved before anything is accepted into the Outbox
        // (roadmap P9.5): a clause without a resolvable citation is never written speculatively, and a
        // Feature or newly authored Card left with zero citable clauses is a thin-spec Refusal — halted
        // here, before any board write this transaction would otherwise make.
        let resolution = await AuthoringCitations.resolve(breakdown, using: citations, context: context)
        if resolution.isThin {
            return try await RefusalRecording.record(
                feature: selection.name,
                finding: RefusalFinding(uncitable: resolution.uncitable, reselectionDepth: reselectionDepth),
                context: context, consecutiveRefusalsMax: consecutiveRefusalsMax
            )
        }

        // Every drafted contract is transcribed before anything is accepted into the Outbox (roadmap
        // P9.6): a Card that needs a contract this author Act cannot read is never authored
        // speculatively — the whole Feature halts, naming every repository it could not read.
        let transcriptions = await AuthoringTranscriptions.resolve(breakdown, using: transcribing, context: context)
        if !transcriptions.isReadable {
            return try await AuthoringHalt.record(
                feature: selection.name, cause: .contractUnreadable(contracts: transcriptions.unreadable),
                context: context
            )
        }

        let scope = try await BoardStateScope.resolve(using: board.provisioning)
        let journal = context.journal
        let attempt = try journal.failedAuthoringTransactionCount(feature: selection.name.rawValue)
        let plan = try AuthoringPlanner(
            selection: selection, breakdown: breakdown, scope: scope, attempt: attempt,
            nightID: context.night.id, journal: journal, citations: resolution,
            transcriptions: transcriptions.cardTranscriptions
        ).plan()
        _ = try journal.acceptOutbox(
            try outbox.drafts(plan.writes, groupID: plan.record.groupKey),
            runID: context.runID,
            appending: .featureAuthoringAccepted(plan.record),
            act: context.act,
            nightID: context.night.id
        )
        return try await complete(plan.record, context: context, outbox: outbox)
    }

    /// Validates the drafted breakdown, returning the outcome to return early with when it is rejected —
    /// nil when it is valid and authoring should continue. A rejected breakdown is an authoring fault,
    /// not a halt (roadmap P9.10; spec: feature-authoring/author-the-cycle-and-card-dag): nothing was
    /// ever accepted into the Outbox, so there is no board write to roll back, no Authoring Halt, and no
    /// Refusal — only `FeatureBreakdownError` is caught here; any other thrown error keeps propagating
    /// and fails the invocation. `.noCards` caused entirely by an Adoption refusal is a quiet Night, not
    /// an authoring fault (roadmap P11.5): the refusal already recorded its own Divergence and Journal
    /// event, so this is `.noWorkAvailable` rather than `.featureBreakdownRejected` — the outcome the
    /// author Act already turns into `.authoringNoWorkAvailable` on its own.
    private func validateBreakdown(
        _ breakdown: FeatureBreakdown, for selection: SelectedFeature, revalidated: AdoptionRevalidation.Outcome,
        context: ActContext
    ) async throws -> FeatureAuthoringOutcome? {
        do {
            try FeatureBreakdownValidation.validate(breakdown, for: selection)
            return nil
        } catch let error as FeatureBreakdownError {
            if case .noCards = error, revalidated.hadRefusals {
                return .noWorkAvailable
            }
            try context.journal.append(
                .featureBreakdownRejected(name: selection.name.rawValue, reason: error.description),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            return .authoringRolledBack
        }
    }

    /// Runs the model-authored breakdown; nil when no Route answered it. That is an authoring fault
    /// (roadmap P9.10, P9.11): nothing was ever accepted into the Outbox, so it is recorded like a
    /// rejected breakdown and the Act ends normally.
    private func draft(_ selection: SelectedFeature, context: ActContext) async throws -> FeatureBreakdown? {
        do {
            return try await drafting.breakdown(for: selection, mainlines: context.mainlines, context: context)
        } catch let fault as AuthoringDispatchFault {
            try context.journal.append(
                .featureBreakdownRejected(name: selection.name.rawValue, reason: fault.reason),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            return nil
        }
    }

    public func resumeUnfinished(_ context: ActContext) async throws -> FeatureAuthoringOutcome? {
        guard let plan = try context.journal.unfinishedAuthoringPlan() else { return nil }
        guard let outbox = context.outbox else { throw AuthoringTransactionError.noBoard }
        return try await complete(plan, context: context, outbox: outbox)
    }

    /// Delivers what is pending, then reads the group's entries: all applied writes the Journal rows,
    /// any failure records the rollback, and anything still pending writes nothing.
    private func complete(
        _ plan: FeatureAuthoringAcceptedPayload, context: ActContext, outbox: Outbox
    ) async throws -> FeatureAuthoringOutcome {
        let journal = context.journal
        _ = try await outbox.deliverPending()
        let entries = try journal.outboxEntries(groupID: plan.groupKey)

        let broken = entries.filter { $0.state == .failed || $0.state == .aborted }
        if !broken.isEmpty {
            let reason = broken.compactMap(\.lastError).first ?? "an authoring write was refused"
            try journal.append(
                .featureAuthoringFailed(name: plan.name, groupKey: plan.groupKey, reason: reason),
                act: context.act, runID: context.runID, nightID: context.night.id
            )
            return .authoringRolledBack
        }
        guard !entries.isEmpty, entries.allSatisfy({ $0.state == .applied }) else {
            return .authoringPending
        }

        func createdID(_ key: String) throws -> String {
            guard let id = entries.first(where: { $0.clientID == outbox.clientID(for: key) })?.result else {
                throw AuthoringTransactionError.appliedEntryWithoutID(key: key)
            }
            return id
        }
        let cards = try plan.cards.map {
            AuthoredCardRow(
                issueID: try createdID($0.key), repository: $0.repository, kind: $0.kind, order: $0.order,
                title: $0.title, clauses: $0.clauses, brief: $0.brief, transcriptions: $0.transcriptions
            )
        }
        try journal.finaliseAuthoring(
            AuthoredFeature(plan: plan, featureIssueID: try createdID(plan.featureKey), cards: cards),
            runID: context.runID, act: context.act, nightID: context.night.id
        )
        // A clean authoring run resets only this Feature's consecutive-refusals count, closes its
        // Refusals so they leave the clock, and clears its Authoring Halts (roadmap P9.7, P9.8) — it
        // never answers a Refusal; only a Spec Citation does. Recorded right after `finaliseAuthoring`'s own
        // transaction, not inside it: the plan's Feature name is a free-text `FeatureName`, not the
        // Journal row `finaliseAuthoring` writes, so there is no shared row to extend that transaction
        // around.
        if let featureName = FeatureName(rawValue: plan.name) {
            try journal.resetConsecutiveRefusals(
                feature: featureName, nightID: context.night.id, act: context.act, runID: context.runID
            )
            try journal.clearAuthoringHalts(
                feature: featureName, nightID: context.night.id, act: context.act, runID: context.runID
            )
        }
        return .authored
    }
}
