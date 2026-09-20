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

    public init(drafting: any FeatureBreakdownDrafting) {
        self.drafting = drafting
    }

    public func author(_ selection: SelectedFeature, context: ActContext) async throws -> FeatureAuthoringOutcome {
        guard let outbox = context.outbox, let board = context.board else {
            throw AuthoringTransactionError.noBoard
        }
        let breakdown = try await drafting.breakdown(for: selection, mainlines: context.mainlines)
        try FeatureBreakdownValidation.validate(breakdown, for: selection)

        let scope = try await BoardStateScope.resolve(using: board.provisioning)
        let journal = context.journal
        let attempt = try journal.failedAuthoringTransactionCount(feature: selection.name.rawValue)
        let plan = try AuthoringPlanner(
            selection: selection, breakdown: breakdown, scope: scope, attempt: attempt,
            nightID: context.night.id, journal: journal
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
            AuthoredCardRow(issueID: try createdID($0.key), repository: $0.repository, kind: $0.kind, order: $0.order)
        }
        try journal.finaliseAuthoring(
            AuthoredFeature(plan: plan, featureIssueID: try createdID(plan.featureKey), cards: cards),
            runID: context.runID, act: context.act, nightID: context.night.id
        )
        return .authored
    }
}
