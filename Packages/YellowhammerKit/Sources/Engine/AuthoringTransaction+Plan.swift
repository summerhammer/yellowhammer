import Domain
import Foundation
import Journal

// The plan half of the authoring transaction (roadmap P9.4): what goes into the one Outbox group, under
// which deterministic keys, and what the Journal is told about it.

/// The Outbox group and the durable plan that describes it.
struct AuthoringPlan: Equatable {
    let writes: [OutboxWrite]
    let record: FeatureAuthoringAcceptedPayload
}

/// Builds one authoring transaction's group. `attempt` is the number of earlier rolled-back transactions
/// for this Feature name, so a retry's keys differ from the failed entries an earlier one left behind.
struct AuthoringPlanner {
    let selection: SelectedFeature
    let breakdown: FeatureBreakdown
    let scope: BoardStateScope
    let attempt: Int
    let nightID: Int64
    let journal: JournalStore

    private var prefix: String { "\(selection.name.rawValue):\(attempt)" }
    private var featureKey: String { "feature:\(prefix):create" }

    /// The group: the Feature Issue create, one adoption per adopted Card, then one Card create per draft
    /// nested under the Feature Issue — so the Feature Issue is applied before anything names it, and a
    /// Card that fails permanently rolls back an adoption that was already applied (the `undo` is
    /// exercised, not just carried).
    ///
    /// Lane order is computed here so the plan and the rows agree: adopted Cards take the first positions
    /// of their repository's lane, in the order given, and newly authored Cards follow.
    ///
    /// No write carries a `cardID`: that would make the Outbox revalidate a Card Lease, and the author Act
    /// holds none — its new Cards are claimed by no one yet, and an adopted Card is left over from a
    /// closed Feature. The Act-scoped Lease still guards every write.
    func plan() throws -> AuthoringPlan {
        var nextOrder: [String: Int] = [:]
        let featureWrite = try featureCreate()
        let (adoptions, adoptionWrites) = try adopt(nextOrder: &nextOrder)
        let (cards, cardWrites) = try create(nextOrder: &nextOrder)
        return AuthoringPlan(
            writes: [featureWrite] + adoptionWrites + cardWrites,
            record: FeatureAuthoringAcceptedPayload(
                name: selection.name.rawValue, groupKey: "authoring:\(prefix)", featureKey: featureKey,
                nightID: nightID, cards: cards, adoptions: adoptions
            )
        )
    }

    private func label(_ name: String) throws -> BoardObjectID {
        guard let id = scope.labels.objectType[name] else {
            throw DispositionLabelsError.missing(group: BoardProvisioner.objectTypeGroup, label: name)
        }
        return id
    }

    private func featureCreate() throws -> OutboxWrite {
        OutboxWrite(key: featureKey, write: .createIssue(
            BoardIssueDraft(
                team: scope.team, title: selection.name.rawValue, description: featureDescription(),
                labels: [try label("Feature")], workflowState: try scope.id(for: .todo)
            ),
            parentKey: nil
        ))
    }

    private func adopt(nextOrder: inout [String: Int]) throws -> ([PlannedAdoption], [OutboxWrite]) {
        var planned: [PlannedAdoption] = []
        var writes: [OutboxWrite] = []
        for issueID in selection.adoptedCardIssueIDs {
            guard let row = try journal.card(issueID: issueID),
                  let previousParent = try journal.featureIssueID(ofCardIssueID: issueID) else {
                throw AuthoringTransactionError.adoptedCardUnknown(issueID: issueID)
            }
            let order = nextOrder[row.repository, default: 0] + 1
            nextOrder[row.repository] = order
            let key = "adopt:\(prefix):\(issueID)"
            planned.append(PlannedAdoption(key: key, cardIssueID: issueID, repository: row.repository, order: order))
            writes.append(OutboxWrite(key: key, write: .adoptIssue(
                issue: BoardObjectID(rawValue: issueID), parentKey: featureKey,
                undo: BoardIssueChange(parent: .set(BoardObjectID(rawValue: previousParent)))
            )))
        }
        return (planned, writes)
    }

    private func create(nextOrder: inout [String: Int]) throws -> ([PlannedCard], [OutboxWrite]) {
        let cardLabel = try label("Card")
        let todo = try scope.id(for: .todo)
        var planned: [PlannedCard] = []
        var writes: [OutboxWrite] = []
        for draft in breakdown.cards {
            let order = nextOrder[draft.repository, default: 0] + 1
            nextOrder[draft.repository] = order
            let key = "card:\(prefix):\(draft.repository):\(order):create"
            planned.append(PlannedCard(
                key: key, repository: draft.repository, kind: draft.kind.description, order: order,
                title: draft.title
            ))
            writes.append(OutboxWrite(key: key, write: .createIssue(
                BoardIssueDraft(
                    team: scope.team, title: draft.title, description: Self.cardDescription(draft),
                    labels: [cardLabel], workflowState: todo
                ),
                parentKey: featureKey
            )))
        }
        return (planned, writes)
    }

    /// Every issue this transaction creates carries a well-formed (near-empty) Managed Block fence, so a
    /// later rewrite finds its delimiters; the prose sits outside it, where a rewrite preserves it. The
    /// Feature's carries the sequence and its reasoning when the selection is one step of a sequence.
    private func featureDescription() -> String {
        var prose = """
            ## Definition of done

            \(breakdown.definitionOfDone)

            ## Why this Feature

            \(selection.reasoning)
            """
        if let sequence = selection.sequence {
            prose += """


                ## Sequence

                - Preceded by: \(sequence.precededBy)
                - Followed by: \(sequence.followedBy)
                - Seam: \(sequence.seam)
                """
        }
        return ManagedBlockFence.initialDescription(rendered: "") + "\n\n" + prose
    }

    private static func cardDescription(_ draft: CardDraft) -> String {
        ManagedBlockFence.initialDescription(rendered: "") + "\n\n" + draft.unitOfWork
    }
}
