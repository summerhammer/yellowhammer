import Domain
import Foundation
import Journal

/// Closes a Feature by merge (roadmap P10.8; spec: landing/announce-a-partial-landing, morning-report/
/// triage-the-morning), the real ``PostMergeClosure``. Called by the predecessor-ancestry gate the first
/// pass that finds every touched repository merged — before that pass's `predecessorAncestryObserved`
/// event, so a throw here leaves the Feature unclosed and is retried by the next pass.
///
/// "Merging costs the Card nothing": a Card still Waiting on You is auto-Blocked with Block Reason
/// `unanswered`, the same exit `unanswered_nights_max` would have given it — its counters and round
/// history untouched. Surviving Blocked Cards are detached from the Feature Issue, awaiting Adoption.
/// The Cycle is archived `closed_by = merge`; the Feature Issue is archived (`issueArchive`) and never
/// moved to Done — the spec leaves the merge-closed state deliberately unnamed, which is how "closed by
/// merge" stays distinguishable from "closed by verification". Never merges or closes a pull request,
/// never reads GitHub.
public struct FeatureMergeClosure: PostMergeClosure, Sendable {
    public init() { }

    public func closeByMerge(feature: FeatureRecord, context: ActContext) async throws {
        // A release lands nothing (P10.9, not yet built); a Feature already closed by verification is
        // already closed — its merge closes nothing further.
        guard feature.releasedAt == nil else { return }
        guard feature.closedBy != .verification else { return }

        let journal = context.journal
        guard let cycleID = try journal.cycleID(featureID: feature.id) else {
            throw CycleArchiveFault(reason: "Feature '\(feature.issueID)' has no recorded Cycle to close by merge")
        }

        try await autoBlockWaitingOnYou(cycleID: cycleID, context: context)

        // Computed after the auto-Block, from Journal state, so a retry (closedBy already `merge`)
        // recomputes the same values rather than trusting anything held in memory.
        let mergedRepositories = try journal.touchedRepositories(featureID: feature.id).sorted()
        let cards = try journal.cards(cycleID: cycleID)
        let blockedCards = cards.filter { $0.state == .blocked }
        let carriedForward = blockedCards.map(\.issueID).sorted()
        let acceptedCards = cards.filter { $0.state == .done }.map(\.issueID).sorted()
        let triagedNightID = try journal.triagedNightID(cycleID: cycleID, currentNightID: context.night.id)

        _ = try journal.closeFeatureByMerge(
            NewFeatureMergeClosure(
                featureID: feature.id, cycleID: cycleID, featureIssueID: feature.issueID,
                triagedNightID: triagedNightID, mergedRepositories: mergedRepositories,
                carriedForward: carriedForward, acceptedCards: acceptedCards, detachedCards: blockedCards.count
            ),
            runID: context.runID, act: context.act, nightID: context.night.id
        )

        let computed = Computed(
            cycleID: cycleID, feature: feature, mergedRepositories: mergedRepositories, blockedCards: blockedCards,
            acceptedCards: acceptedCards, triagedNightID: triagedNightID
        )
        try await postBoardWrites(computed, context: context)
    }

    /// What ``closeByMerge(feature:context:)`` computed, bundled so
    /// ``postBoardWrites(_:context:)`` stays under the parameter-count limit.
    private struct Computed {
        let cycleID: Int64
        let feature: FeatureRecord
        let mergedRepositories: [String]
        let blockedCards: [CardRecord]
        let acceptedCards: [String]
        let triagedNightID: Int64
    }

    /// Every Waiting on You Card of the Cycle is auto-Blocked `unanswered` — the same exit
    /// `unanswered_nights_max` would have given it, with its counters and round history untouched.
    /// Cancelled, Done and already-Blocked Cards are never touched. Through the board projection when
    /// an Outbox and board are wired; Journal-only otherwise, so the auto-Block still happens.
    private func autoBlockWaitingOnYou(cycleID: Int64, context: ActContext) async throws {
        let journal = context.journal
        let waiting = try journal.cards(cycleID: cycleID).filter { $0.state == .waitingOnYou }
        guard !waiting.isEmpty else { return }

        if let outbox = context.outbox, let board = context.board {
            let scope = try await BoardStateScope.resolve(using: board.provisioning)
            let projection = BoardStateProjection(journal: journal, outbox: outbox, scope: scope)
            for card in waiting {
                // A Card's state write is delivered only under that Card's Lease, and this Act runs no
                // Card: claim it for the one write, then release it, as the expired-lease sweep does — a
                // lease left to expire would later read as a crashed run. A live lease held by another run
                // throws, so this closure is retried by the next ancestry pass rather than writing under it.
                if case .held(let holder) = try journal.claimCardLease(cardID: card.id, runID: context.runID) {
                    throw CycleArchiveFault(
                        reason: "Card '\(card.issueID)' is held by run \(holder.runID); its auto-Block is retried"
                    )
                }
                do {
                    _ = try await projection.transition(card: card, to: .blocked(.unanswered))
                } catch {
                    _ = try? journal.releaseCardLease(cardID: card.id, runID: context.runID)
                    throw error
                }
                try journal.releaseCardLease(cardID: card.id, runID: context.runID)
            }
        } else {
            for card in waiting {
                _ = try journal.transitionCard(
                    cardID: card.id, to: .blocked, blockReason: .unanswered, runID: context.runID,
                    act: context.act, nightID: context.night.id
                )
            }
        }
    }

    /// The narrative comment, each Blocked Card's detachment, and the Feature Issue's archival — every
    /// write keyed on the Cycle so a retry re-queues the same writes rather than duplicating them.
    /// Never a workflow-state write to Done. Skipped entirely when no Outbox or board is wired.
    private func postBoardWrites(_ computed: Computed, context: ActContext) async throws {
        guard let outbox = context.outbox, context.board != nil else { return }
        let journal = context.journal
        let cycleID = computed.cycleID
        let feature = computed.feature
        let blockedCards = computed.blockedCards
        let issue = BoardObjectID(rawValue: feature.issueID)

        let landings = try journal.landings(featureID: feature.id)
        let carriedForwardCards = blockedCards.map {
            FeatureMergeClosureComment.CarriedForwardCard(
                issueID: $0.issueID, blockReason: $0.blockReason.flatMap { BlockReason(rawValue: $0) }
            )
        }
        let verification = try journal.featureVerification(cycleID: cycleID)
        let unmetClauses = verification?.clauses.filter { $0.verdict != .met } ?? []
        let triagedNight = try journal.night(id: computed.triagedNightID)
        let comment = FeatureMergeClosureComment(
            landings: landings, carriedForward: carriedForwardCards, acceptedCards: computed.acceptedCards,
            unmetClauses: unmetClauses, triagedNightStart: triagedNight?.nightStart ?? context.night.nightStart,
            observingNightStart: context.night.nightStart
        ).body()

        let commentKey = "merge:\(cycleID):closed:\(feature.issueID)"
        _ = try await outbox.post(OutboxWrite(key: commentKey, write: .createComment(issue: issue, body: comment)))

        for card in blockedCards {
            let key = "merge:\(cycleID):detach:\(card.issueID)"
            let cardIssue = BoardObjectID(rawValue: card.issueID)
            let change = BoardIssueChange(parent: .clear)
            let write = OutboxWrite(key: key, write: .updateIssue(issue: cardIssue, change: change, undo: nil))
            _ = try await outbox.post(write)
        }

        let archiveKey = "merge:\(cycleID):archive:\(feature.issueID)"
        _ = try await outbox.post(OutboxWrite(key: archiveKey, write: .archiveIssue(issue: issue)))
    }
}
