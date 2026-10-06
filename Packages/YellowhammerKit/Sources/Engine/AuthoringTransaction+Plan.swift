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
    /// The clauses ``AuthoringCitations`` resolved as citable, and every clause it dropped (roadmap
    /// P9.5). Only citable clauses are minted and written; dropped ones are recorded on the plan.
    let citations: AuthoringCitationResolution
    /// Per-Card Transcription Blocks ``AuthoringTranscriptions`` read (roadmap P9.6), aligned by index
    /// with `breakdown.cards`.
    let transcriptions: [[TranscriptionBlock]]

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
        let featureClauses = Self.mint(citations.featureClauses)
        let (adoptions, adoptionWrites) = try adopt(nextOrder: &nextOrder)
        let featureWrite = try featureCreate(clauses: featureClauses, adoptions: adoptions)
        let (cards, cardWrites) = try create(nextOrder: &nextOrder)
        let uncitable = citations.uncitable.map {
            PlannedUncitableClause(
                level: $0.level, cardTitle: $0.cardTitle, text: $0.text, citation: $0.citation, reason: $0.reason
            )
        }
        return AuthoringPlan(
            writes: [featureWrite] + adoptionWrites + cardWrites,
            record: FeatureAuthoringAcceptedPayload(
                name: selection.name.rawValue, groupKey: "authoring:\(prefix)", featureKey: featureKey,
                nightID: nightID, cards: cards, adoptions: adoptions,
                featureClauses: featureClauses, uncitableClauses: uncitable,
                repositories: selection.repositories
            )
        )
    }

    /// Mints synthetic `cid`s for one issue's citable clauses, in draft order: `c1`, `c2`, … — the Feature
    /// Issue and each new Card are brand new, so this equals what ``JournalStore/nextClauseID(issueID:)``
    /// would give a fresh issue (roadmap P9.5).
    private static func mint(_ drafts: [DefinitionOfDoneClauseDraft]) -> [PlannedClause] {
        drafts.enumerated().map { index, draft in
            PlannedClause(cid: "c\(index + 1)", text: draft.text, citation: draft.citation.rawValue)
        }
    }

    /// Carries every transcribed Transcription Block onto the plan (roadmap P9.6): never Operator-
    /// supplied at authoring time.
    private static func mintTranscriptions(_ blocks: [TranscriptionBlock]) -> [PlannedTranscription] {
        blocks.map {
            PlannedTranscription(
                repository: $0.repository, paths: $0.paths, symbol: $0.symbol, mainlineCommit: $0.mainlineCommit,
                content: $0.content, contentHash: $0.contentHash
            )
        }
    }

    private func label(_ type: CardType) throws -> BoardObjectID {
        guard let id = scope.labels.cardType[type] else {
            throw DispositionLabelsError.missing(group: BoardProvisioner.cardTypeGroup, label: type.rawValue)
        }
        return id
    }

    private func featureCreate(clauses: [PlannedClause], adoptions: [PlannedAdoption]) throws -> OutboxWrite {
        OutboxWrite(key: featureKey, write: .createIssue(
            BoardIssueDraft(
                team: scope.team, title: selection.name.rawValue,
                description: featureDescription(clauses: clauses, adoptions: adoptions),
                labels: [try label(.featureCard)], workflowState: try scope.id(for: .todo)
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
            planned.append(PlannedAdoption(
                key: key, cardIssueID: issueID, repository: row.repository, order: order,
                previousFeatureIssueID: previousParent
            ))
            writes.append(OutboxWrite(key: key, write: .adoptIssue(
                issue: BoardObjectID(rawValue: issueID), parentKey: featureKey,
                undo: BoardIssueChange(parent: .set(BoardObjectID(rawValue: previousParent)))
            )))
        }
        return (planned, writes)
    }

    private func create(nextOrder: inout [String: Int]) throws -> ([PlannedCard], [OutboxWrite]) {
        let cardLabel = try label(.workCard)
        let todo = try scope.id(for: .todo)
        var planned: [PlannedCard] = []
        var writes: [OutboxWrite] = []
        for (index, draft) in breakdown.cards.enumerated() {
            let order = nextOrder[draft.repository, default: 0] + 1
            nextOrder[draft.repository] = order
            let key = "card:\(prefix):\(draft.repository):\(order):create"
            let clauses = Self.mint(citations.cardClauses[index])
            let blocks = transcriptions[index]
            let plannedTranscriptions = Self.mintTranscriptions(blocks)
            planned.append(PlannedCard(
                key: key, repository: draft.repository, kind: draft.kind.description, order: order,
                title: draft.title, clauses: clauses, brief: draft.brief, transcriptions: plannedTranscriptions
            ))
            writes.append(OutboxWrite(key: key, write: .createIssue(
                BoardIssueDraft(
                    team: scope.team, title: draft.title,
                    description: Self.cardDescription(draft, clauses: clauses, transcriptions: blocks),
                    labels: [cardLabel], workflowState: todo
                ),
                parentKey: featureKey
            )))
        }
        return (planned, writes)
    }

    /// The Definition of Done section both descriptions share: a heading and one checklist line per
    /// citable clause (roadmap P9.5).
    private static func definitionOfDoneLines(_ clauses: [PlannedClause]) -> [String] {
        clauses.map { DefinitionOfDoneClauseLine.render(cid: $0.cid, text: $0.text, citation: $0.citation) }
    }

    /// Every issue this transaction creates carries a well-formed (near-empty) Managed Block fence, so a
    /// later rewrite finds its delimiters; the prose sits outside it, where a rewrite preserves it. The
    /// Feature's carries the sequence and its reasoning when the selection is one step of a sequence. Its
    /// Definition of Done is authored as prose (outside the fence) — the checklist the Operator reads.
    private func featureDescription(clauses: [PlannedClause], adoptions: [PlannedAdoption]) -> String {
        let checklist = Self.definitionOfDoneLines(clauses).joined(separator: "\n")
        var prose = """
            ## Definition of done

            \(checklist)

            ## Why this Feature

            \(selection.reasoning)
            """
        if !adoptions.isEmpty {
            let lines = adoptions.map { "- \($0.cardIssueID), adopted from \($0.previousFeatureIssueID)" }
                .joined(separator: "\n")
            prose += """


                ## Adopted Cards

                \(lines)
                """
        }
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

    /// A Card's Architectural Brief and Definition of Done are both authored inside the Managed Block
    /// fence, brief first (roadmap P9.6), so ``CardManagedBlockParser`` reads the prose, the Transcription
    /// Blocks and the clauses straight back — the Readiness Check marks a Journal clause missing from the
    /// board as deleted, so this must round-trip exactly. The unit-of-work prose stays outside the fence,
    /// as before.
    private static func cardDescription(
        _ draft: CardDraft, clauses: [PlannedClause], transcriptions: [TranscriptionBlock]
    ) -> String {
        var lines = ["### Architectural Brief", draft.brief]
        for block in transcriptions {
            lines.append(contentsOf: Self.transcriptionLines(block))
        }
        lines.append("")
        lines.append(contentsOf: ["### Definition of Done"] + definitionOfDoneLines(clauses))
        let rendered = lines.joined(separator: "\n")
        return ManagedBlockFence.initialDescription(rendered: rendered) + "\n\n" + draft.unitOfWork
    }

    /// Renders one freshly transcribed Transcription Block via the shared formatter (roadmap P9.6), so
    /// this initial description is byte-identical to what a later Managed Block rewrite would emit for
    /// the same block. Never Operator-supplied at authoring time.
    private static func transcriptionLines(_ block: TranscriptionBlock) -> [String] {
        TranscriptionBlockLine.render(block)
    }
}
