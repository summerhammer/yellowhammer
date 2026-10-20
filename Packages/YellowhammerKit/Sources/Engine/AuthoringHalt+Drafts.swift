import Domain
import Foundation
import Journal

/// A halted Feature's draft children (roadmap P22.6; spec: feature-authoring/select-the-next-feature,
/// `#halted-authoring-repair`). A halt that arises after a breakdown was produced keeps that breakdown in its
/// checkpoint FIRST, and only then posts the breakdown's Work Cards as repairable draft children beneath the
/// halted Feature Card — each create through the Outbox under a key that makes its client id deterministic, each
/// returned issue id recorded before the next write.
///
/// A draft is visibly not accepted work: it sits in the team's native `backlog`-category state when one resolves,
/// carries the `Work Card` Card Type, and leads with ``headline``. It has no `card` row, so nothing dispatches it,
/// no Cycle counts it, and no overdue clock reads it.
enum HaltDrafts {
    /// What the first line of every draft says. It sits inside the Managed Block, so the first rewrite of the
    /// block (the one that turns a repaired draft into a Work Card) takes it away.
    static let headline = "> **Draft — not accepted; edit it, then move the Feature to Todo.**"

    static func outboxKey(feature: FeatureName, haltID: Int64, position: Int) -> String {
        "feature:\(feature.rawValue):authoring-halt:\(haltID):draft:\(position):create"
    }

    /// Posts every draft the checkpointed breakdown asks for that has no issue yet. Safe to run again after a
    /// crash at any point: the drafts are registered once, and a create already accepted is never sent twice.
    /// An issue the Operator deleted or canceled keeps its id on its row, so it is never created again.
    static func ensurePosted(halt: AuthoringHaltRecord, context: ActContext) async throws {
        let journal = context.journal
        guard let outbox = context.outbox, let board = context.board, let parent = halt.issueID,
              let feature = FeatureName(rawValue: halt.featureName),
              let breakdown = try journal.authoringHaltCheckpoint(haltID: halt.id)?.breakdown,
              !breakdown.cards.isEmpty
        else { return }
        let seeds = breakdown.cards.enumerated().map { index, card in
            AuthoringHaltDraftSeed(
                outboxKey: outboxKey(feature: feature, haltID: halt.id, position: index + 1),
                position: index + 1, repository: card.repository, kind: card.kind.description, title: card.title
            )
        }
        try journal.registerAuthoringHaltDrafts(haltID: halt.id, seeds: seeds)
        let pending = try journal.authoringHaltDrafts(haltID: halt.id)
            .filter { $0.issueID == nil && $0.source == .authored }
        guard !pending.isEmpty else { return }
        let scope = try await BoardStateScope.resolve(using: board.provisioning)
        guard let label = scope.labels.cardType[.workCard] else {
            throw DispositionLabelsError.missing(
                group: BoardProvisioner.cardTypeGroup, label: CardType.workCard.rawValue
            )
        }
        let hold = try await board.provisioning.workflowStates(team: scope.team).first { $0.category == .backlog }
        for draft in pending {
            guard let key = draft.outboxKey, breakdown.cards.indices.contains(draft.position - 1) else { continue }
            let card = breakdown.cards[draft.position - 1]
            let delivery = try await outbox.post(OutboxWrite(key: key, write: .createIssue(
                BoardIssueDraft(
                    team: scope.team, title: card.title, description: description(of: card),
                    parent: BoardObjectID(rawValue: parent), labels: [label], workflowState: hold?.id
                ),
                parentKey: nil
            )))
            let created: String?
            switch delivery.outcome {
            case .applied(let id): created = id?.rawValue ?? delivery.entry.result
            case .alreadyApplied(let id): created = id.rawValue
            default: created = delivery.entry.result
            }
            if let created {
                try journal.recordAuthoringHaltDraftIssue(haltID: halt.id, outboxKey: key, issueID: created)
            }
        }
    }

    /// The draft's description: a Managed Block that the Card parser reads back, then the unit of work. Kind,
    /// Repository and Scope lines are the supported fields an Operator edits; the contracts are references only.
    static func description(of card: CardDraft) -> String {
        var lines = [headline, "", "**Kind:** `\(card.kind)`", "**Repository:** `\(card.repository)`"]
        lines.append("**Scope:** _none declared_")
        lines.append("")
        lines.append("### Architectural Brief")
        lines.append(contentsOf: ArchitecturalBriefProseRegion.render(card.brief))
        for contract in card.contracts {
            lines.append(contentsOf: TranscriptionBlockLine.render(TranscriptionBlock(
                repository: contract.repository, paths: contract.paths, ranges: contract.ranges,
                symbol: contract.symbol, mainlineCommit: nil, content: "", contentHash: "", authorSupplied: false
            )))
        }
        lines.append("")
        lines.append("### Definition of Done")
        for clause in card.definitionOfDone {
            lines.append("- [ ] \(clause.text) (\(clause.citation.rawValue))")
        }
        return ManagedBlockFence.initialDescription(rendered: lines.joined(separator: "\n")) + "\n\n" + card.unitOfWork
    }
}
