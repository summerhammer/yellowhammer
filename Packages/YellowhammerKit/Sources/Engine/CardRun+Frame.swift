import Domain
import Foundation
import Journal

/// What one Card run holds while it runs: the Card, where it runs, and the board projection it writes
/// through. Rebuilt from the Journal and the Delta Read on every run — nothing here outlives it.
struct CardRunFrame: Sendable {
    var card: CardRecord
    let context: BuildActContext
    let readiness: CardReadiness
    let repository: Repo?
    let check: Check
    let worktree: WorktreeRecord
    let branch: FeatureBranch
    let projection: BoardStateProjection?
    let instructionCard: InstructionCard
    /// Set once the Route is resolved and the Attempt recorded.
    var attempt: AttemptRecord?
    var route: Route?

    var journal: JournalStore { context.act.journal }

    /// Throws ``JournalError/cardLeaseLost(cardID:runID:holder:)`` unless this run still holds the Card's
    /// Lease. Called before every Journal or board write that records an outcome: sleep is more dangerous
    /// than a crash.
    func revalidateLease() throws {
        _ = try journal.revalidateCardLease(cardID: card.id, runID: context.act.runID)
    }

    func record(_ step: CardRunStep, detail: String? = nil) throws {
        try journal.append(
            .cardRunStep(cardID: card.id, issueID: card.issueID, step: step, detail: detail),
            act: context.act.act, runID: context.act.runID, nightID: context.act.night.id
        )
    }

    /// Transitions the Card through the board projection, or on the Journal alone when the invocation has
    /// no Board (a later Act reposts it).
    func transition(_ transition: CardTransition) async throws {
        try revalidateLease()
        let current = try journal.card(id: card.id)
        if let projection {
            _ = try await projection.transition(card: current, to: transition)
        } else {
            try journal.transitionCard(
                cardID: card.id, to: transition.state, waitingReason: transition.waitingReason,
                blockReason: transition.blockReason, runID: context.act.runID, act: context.act.act,
                nightID: context.act.night.id
            )
        }
    }

    /// The Override the Operator pinned on this Card's board object, read from the Delta Read's copy of it;
    /// none when the Delta Read did not see the Card change or this invocation has no Board.
    func override() async throws -> Override {
        guard let object = changedObject, let board = context.act.board, let projection else {
            return .none
        }
        let labels = try await board.provisioning.labels(team: projection.scope.team)
        return OverrideLabels(labels: labels).override(on: object)
    }

    /// The Card's board object, when this Card is among the Delta Read's changes.
    var changedObject: BoardObject? {
        context.deltaRead?.cardChanges.first { $0.card.id == card.id }?.object
    }
}

extension CardRun {
    /// Gathers what the run needs before anything is spent: an Attempt is never recorded for a Card that
    /// cannot be dispatched for want of a Worktree, a Feature Branch or a declared Check.
    func prepare(card: CardRecord, context: BuildActContext, readiness: CardReadiness) async throws -> CardRunFrame {
        let journal = context.act.journal
        guard let worktree = try journal.heldWorktree(featureID: context.feature.id, repository: card.repository) else {
            throw CardRunError.worktreeMissing(featureID: context.feature.id, repository: card.repository)
        }
        guard let branch = context.feature.branch else {
            throw BuildActError.featureBranchUnrecorded(featureID: context.feature.id)
        }
        guard let check = checks[card.repository] else {
            throw CardRunError.checkUnknown(repository: card.repository)
        }

        var projection: BoardStateProjection?
        if let board = context.act.board, let outbox = context.act.outbox {
            let scope = try await BoardStateScope.resolve(using: board.provisioning)
            projection = BoardStateProjection(journal: journal, outbox: outbox, scope: scope)
        }

        // The Journal stores no Card title. The Delta Read's board object carries one only when the Card
        // changed since the last read, so an unchanged Card is titled by its issue id: a known gap.
        let object = context.deltaRead?.cardChanges.first { $0.card.id == card.id }?.object
        return CardRunFrame(
            card: card, context: context, readiness: readiness,
            repository: context.act.repositories?.workingRepo(named: card.repository), check: check,
            worktree: worktree, branch: branch, projection: projection,
            instructionCard: InstructionCard(
                key: card.issueID, title: object?.title ?? card.issueID, description: object?.description
            )
        )
    }
}
