import Domain
import Foundation
import Journal

// The authoring transaction's description budget check (spec: feature-authoring/author-the-cycle-and-
// features-work-cards, "description limit"). Every description the transaction composes is measured against
// the Board Connection's description budget before anything is accepted into the Outbox, and measured at
// its largest *maintained* rendering, so a later Managed Block rewrite can always compact to fit.

/// A description the authoring transaction composed that is over the budget.
struct AuthoringBudgetViolation: Equatable {
    enum Subject: Equatable {
        /// A Work Card over the budget makes the breakdown invalid output: the Route walk moves on.
        case workCard
        /// A Feature Card over the budget is an authoring fault at once; no Route would change it.
        case featureCard
    }

    let subject: Subject
    /// One line naming the card, its size against the budget and its sections by size. Never ends in a
    /// period: the Night Card's fault line adds its own.
    let reason: String
}

struct AuthoringDescriptionBudget {
    let budget: DescriptionBudget
    /// The widest Route of the whole Routing Table, which the room for a Work Card's Attempts is sized with.
    /// Nil when the drafting knows none (a drafting that dispatched no Route): the Attempts section is then
    /// measured as it renders at authoring.
    let longestRoute: Route?

    /// The first description over the budget, the Feature Card's before any Work Card's; nil when all fit.
    func violation(
        plan: AuthoringPlan, planner: AuthoringPlanner, breakdown: FeatureBreakdown,
        transcriptions: [[TranscriptionBlock]], journal: JournalStore
    ) throws -> AuthoringBudgetViolation? {
        if let feature = try featureViolation(plan: plan, planner: planner, journal: journal) {
            return feature
        }
        let digits = max(2, String(plan.record.cards.count + plan.record.adoptions.count).count)
        let lane = Int(String(repeating: "9", count: digits)) ?? 99
        for (index, card) in plan.record.cards.enumerated() {
            let created = plan.writes.compactMap { write -> String? in
                guard case .createIssue(let draft, _) = write.write, draft.title == card.title else { return nil }
                return draft.description
            }
            if let violation = workCardViolation(
                card, draft: breakdown.cards[index], blocks: transcriptions[index], lane: lane, created: created
            ) {
                return violation
            }
        }
        return nil
    }

    // MARK: - Work Card

    /// A Work Card is measured as the Managed Block a later rewrite renders at its largest — its Attempts
    /// section replaced by the widest fully compacted one, its State line at the longest state — fenced as
    /// ``ManagedBlockFence/initialDescription(rendered:)`` fences it, plus the unit of work outside the
    /// fence. Left out, as free text or absent at authoring: a Block Reason, a Failure-Cause Recurrence, an
    /// adoption refusal notice, un-adopted standing, and the declared Scope (set by the worker, shown as
    /// `_none declared_` here).
    private func workCardViolation(
        _ card: PlannedCard, draft: CardDraft, blocks: [TranscriptionBlock], lane: Int, created: [String]
    ) -> AuthoringBudgetViolation? {
        let (block, maintained) = maintainedWorkCard(WorkCardShape(
            kind: card.kind, repository: card.repository, lane: lane,
            brief: ArchitecturalBrief(prose: card.brief, transcriptions: blocks),
            clauses: card.clauses.map {
                DoDClause(cid: $0.cid, text: $0.text, citation: $0.citation, citationProvenance: "")
            },
            unitOfWork: draft.unitOfWork
        ))
        let size = max(budget.measure(maintained), created.map(budget.measure).max() ?? 0)
        guard size > budget.value else { return nil }

        let brief = budget.measure(card.brief)
        let transcription = budget.measure(block.renderTranscriptions().joined(separator: "\n"))
        let definition = budget.measure(block.renderDefinitionOfDone().joined(separator: "\n"))
        let unit = budget.measure(draft.unitOfWork)
        let rest = max(0, size - brief - transcription - definition - unit)
        let sections = [
            (WorkCardDescriptionSection.brief.title, brief),
            (WorkCardDescriptionSection.transcriptionReferences.title, transcription),
            (WorkCardDescriptionSection.definitionOfDone.title, definition),
            (WorkCardDescriptionSection.unitOfWork.title, unit),
            (WorkCardDescriptionSection.restOfManagedBlock.title, rest)
        ]
        return AuthoringBudgetViolation(
            subject: .workCard,
            reason: wording("Work Card \"\(card.title)\" (\(card.repository))", size: size, sections: sections)
        )
    }

    /// The one rendering of a Work Card at its largest maintained form, which both the check and the room
    /// the breakdown is told are measured from: the Managed Block at the longest state and the widest
    /// Attempts reserve, fenced, with the unit of work after it. Returns the block as well, for the sections.
    private func maintainedWorkCard(_ shape: WorkCardShape) -> (block: CardManagedBlock, description: String) {
        let longestState = CardState.allCases.max { $0.rawValue.count < $1.rawValue.count } ?? .waitingOnYou
        let block = CardManagedBlock(
            kind: shape.kind, repository: shape.repository, state: longestState, lanePosition: shape.lane,
            laneLength: shape.lane, brief: shape.brief, definitionOfDone: shape.clauses, attempts: []
        )
        let rendered = longestRoute.map { block.renderReservingAttempts(longestRoute: $0) } ?? block.render()
        return (block, ManagedBlockFence.initialDescription(rendered: rendered) + "\n\n" + shape.unitOfWork)
    }

    /// What of a Work Card its description depends on.
    private struct WorkCardShape {
        let kind: String
        let repository: String
        let lane: Int
        let brief: ArchitecturalBrief
        let clauses: [DoDClause]
        let unitOfWork: String
    }

    // MARK: - Room

    /// What the budget leaves a Work Card in each of `repositories`, and what one clause and one contract
    /// reference cost beyond their content, measured from the very rendering ``workCardViolation`` measures.
    ///
    /// A Card with no clauses, no references and empty text renders a fixed part. With n clauses the
    /// `_No clauses authored._` line is replaced by n clause lines joined by newlines, so each costs its
    /// line plus one; the kind is measured as the root Kind `*`, whose length the room takes back, so the
    /// kind's own text counts toward the room. The brief and the unit of work add exactly their length.
    func room(repositories: [String]) -> BreakdownDescriptionRoom {
        let lane = 99
        let placeholder = budget.measure(CardManagedBlock.noClausesLine)
        let root = Kind.any.description
        let rooms = repositories.map { repository in
            let empty = maintainedWorkCard(WorkCardShape(
                kind: root, repository: repository, lane: lane,
                brief: ArchitecturalBrief(prose: "", transcriptions: []), clauses: [], unitOfWork: ""
            )).description
            let fixed = budget.measure(empty) - budget.measure(root) - placeholder - budget.measure("\n")
            return BreakdownDescriptionRoom.RepositoryRoom(repository: repository, room: budget.value - fixed)
        }
        let clause = DefinitionOfDoneClauseLine.render(cid: "c1", text: "", citation: "")
        let reference = referenceLength(paths: [])
        let path = referenceLength(paths: ["", ""]) - referenceLength(paths: [""])
        return BreakdownDescriptionRoom(
            budget: budget, rooms: rooms, clauseOverhead: budget.measure(clause) + 1,
            referenceOverhead: reference, pathOverhead: path
        )
    }

    /// A contract reference's length in the Managed Block with `paths` and nothing else named: the lines
    /// of the block joined by newlines, and the newline joining it to what precedes. A second path costs
    /// more than the first (the first has no separator before it), so the difference is an upper bound.
    private func referenceLength(paths: [String]) -> Int {
        let block = TranscriptionBlock(
            repository: "", paths: paths, mainlineCommit: String(repeating: "0", count: 40), content: "",
            contentHash: "", authorSupplied: false
        )
        return budget.measure(TranscriptionBlockLine.render(block).joined(separator: "\n")) + 1
    }

    // MARK: - Feature Card

    /// The Feature Card is measured with its Roll-up at its largest for its member set: every new Card by
    /// its drafted title and repository, every adopted Card by its Journal title or issue id with its
    /// "adopted from" marker, each at its longest state, reason and marker wording
    /// (``FeatureRollUpBlock/largestRendering(of:repositories:)``). Left out as free text: a title the board
    /// later gives an adopted Card the Journal has none for, and the issue id Linear assigns a new Card.
    private func featureViolation(
        plan: AuthoringPlan, planner: AuthoringPlanner, journal: JournalStore
    ) throws -> AuthoringBudgetViolation? {
        var members = plan.record.cards.map {
            RollUpMember(issueID: "", title: $0.title, repository: $0.repository, authoredOrder: $0.order, state: .todo)
        }
        for adoption in plan.record.adoptions {
            let title = try journal.card(issueID: adoption.cardIssueID)?.title
            members.append(RollUpMember(
                issueID: adoption.cardIssueID, title: title, repository: adoption.repository,
                authoredOrder: adoption.order, state: .todo,
                adoptedFromFeatureIssueID: adoption.previousFeatureIssueID
            ))
        }
        let rollUp = FeatureRollUpBlock.largestRendering(of: members, repositories: planner.selection.repositories)
        let clauses = plan.record.featureClauses
        let adoptions = plan.record.adoptions
        let maintained = planner.featureDescription(clauses: clauses, adoptions: adoptions, rolledUp: rollUp)
        let created = plan.writes.compactMap { write -> String? in
            guard case .createIssue(let draft, nil) = write.write else { return nil }
            return draft.description
        }
        let size = max(budget.measure(maintained), created.map(budget.measure).max() ?? 0)
        guard size > budget.value else { return nil }

        let prose = planner.featureSections(clauses: clauses, adoptions: adoptions)
        var sections = prose.map { ($0.title, budget.measure($0.text)) }
        sections.append(("the roll-up", max(0, size - sections.map(\.1).reduce(0, +))))
        return AuthoringBudgetViolation(
            subject: .featureCard,
            reason: wording("Feature Card \"\(planner.selection.name.rawValue)\"", size: size, sections: sections)
        )
    }

    // MARK: - Wording

    /// `Work Card "T" (repo) composes 12,345 UTF-16 code units, over the description budget of 10,000: A 9,100;
    /// B 2,000`, largest section first, empty sections left out.
    private func wording(_ card: String, size: Int, sections: [(String, Int)]) -> String {
        let unit = budget.limit.unit.plural
        let named = sections.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
            .map { "\($0.0) \(Self.grouped($0.1))" }.joined(separator: "; ")
        return "\(card) composes \(Self.grouped(size)) \(unit), over the description budget of "
            + "\(Self.grouped(budget.value)): \(named)"
    }

    private static func grouped(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}
