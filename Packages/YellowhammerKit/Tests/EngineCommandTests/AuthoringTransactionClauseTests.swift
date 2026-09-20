import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// roadmap P9.5 (spec: feature-authoring/author-citable-definitions-of-done): the authoring transaction
// resolves every drafted clause's citation before anything is accepted into the Outbox, mints synthetic
// ids per issue, writes the checklist line format to the board and the `clause` table to the Journal,
// drops what does not resolve, and refuses a Feature whose spec support is too thin. These assert
// format, rows and the refusal path — never what a breakdown's clause text says.

@Suite("Authoring transaction: citable Definitions of Done (P9.5)")
struct AuthoringTransactionClauseTests {
    @Test("""
        The Feature Issue's checklist and every Card's Managed Block carry the mandated clause line, \
        and the Card's round-trips through the parser
        """)
    func clauseLinesAreRenderedAndParseBack() async throws {
        let rig = try await AuthoringRig()
        let outcome = try await rig.run(rig.context())

        #expect(outcome == .authored)
        let live = await rig.boards.writing.liveIssues
        let feature = try #require(live.first { $0.title == "FEAT-1" })
        let featureDescription = try #require(feature.description)
        #expect(featureDescription.contains("- [ ] <!-- yh:clause:c1 --> The Feature is done. (resolvable/story)"))

        let backendOne = try #require(live.first { $0.title == "Backend one" })
        let cardDescription = try #require(backendOne.description)
        #expect(cardDescription.contains("### Definition of Done"))
        let expectedLine = "- [ ] <!-- yh:clause:c1 --> Backend one is done. (resolvable/story)"
        #expect(cardDescription.contains(expectedLine))

        guard case .success(let parts) = ManagedBlockFence.parts(of: cardDescription) else {
            Issue.record("Card description is not fenced")
            return
        }
        let parsed = CardManagedBlockParser.parse(block: parts.block)
        let expectedClause = ParsedClause(cid: "c1", text: "Backend one is done.", citation: "resolvable/story")
        #expect(parsed.clauses == [expectedClause])
    }

    @Test("""
        Every citable clause is written to the Journal's clause table: Feature and Card level, \
        cids minted per issue
        """)
    func clausesAreJournaled() async throws {
        let rig = try await AuthoringRig()
        let outcome = try await rig.run(rig.context())

        #expect(outcome == .authored)
        let live = await rig.boards.writing.liveIssues
        let feature = try #require(live.first { $0.title == "FEAT-1" })
        let featureClauses = try rig.journal.clauses(issueID: feature.id.rawValue)
        #expect(featureClauses.count == 1)
        let featureClause = try #require(featureClauses.first)
        #expect(featureClause.cid == "c1")
        #expect(featureClause.level == "feature")
        #expect(featureClause.text == "The Feature is done.")
        #expect(featureClause.locationID == "resolvable/story")
        #expect(featureClause.provenance == "machine-found")
        #expect(featureClause.citationProvenance == "machine-found")

        for card in live where card.id != feature.id {
            let clauses = try rig.journal.clauses(issueID: card.id.rawValue)
            #expect(clauses.count == 1)
            #expect(clauses.first?.cid == "c1")
            #expect(clauses.first?.level == "card")
        }
    }

    @Test("An uncitable clause among citable ones is dropped from the board and the Journal, and recorded on the plan")
    func uncitableClauseIsDroppedAndRecorded() async throws {
        let kind = try authoringKind()
        let breakdown = FeatureBreakdown(
            definitionOfDone: [authoringClause("The Feature is done.")],
            cards: [
                CardDraft(
                    repository: "backend", kind: kind, title: "Backend one", unitOfWork: "Do it",
                    definitionOfDone: [
                        authoringClause("Backend one is done."),
                        DefinitionOfDoneClauseDraft(text: "Unreachable", citation: "epic/ghost")
                    ]
                ),
                CardDraft(
                    repository: "mobile", kind: kind, title: "Mobile one", unitOfWork: "Do it",
                    definitionOfDone: [authoringClause("Mobile one is done.")]
                )
            ]
        )
        let rig = try await AuthoringRig(drafting: ScriptedBreakdown(breakdown))

        let outcome = try await rig.run(rig.context())

        #expect(outcome == .authored)
        let live = await rig.boards.writing.liveIssues
        let backendOne = try #require(live.first { $0.title == "Backend one" })
        let description = try #require(backendOne.description)
        #expect(!description.contains("Unreachable"))
        let clauses = try rig.journal.clauses(issueID: backendOne.id.rawValue)
        #expect(clauses.map(\.text) == ["Backend one is done."])

        let event = try #require(try rig.journal.events(ofType: .featureAuthoringAccepted).first)
        guard case .featureAuthoringAccepted(let plan) = event.event else {
            Issue.record("expected featureAuthoringAccepted")
            return
        }
        #expect(plan.uncitableClauses.count == 1)
        let dropped = try #require(plan.uncitableClauses.first)
        #expect(dropped.level == "card")
        #expect(dropped.cardTitle == "Backend one")
        #expect(dropped.text == "Unreachable")
        #expect(dropped.citation == "epic/ghost")
    }

    @Test("""
        A Feature left with zero Feature-level clauses is refused: nothing is accepted, no Attempt, \
        the Feature reads Waiting on You
        """)
    func thinFeatureLevelRefusesAuthoring() async throws {
        let breakdown = try authoringBreakdown()
        let thin = FeatureBreakdown(
            definitionOfDone: [DefinitionOfDoneClauseDraft(text: "Uncitable", citation: "epic/ghost")],
            cards: breakdown.cards
        )
        let rig = try await AuthoringRig(drafting: ScriptedBreakdown(thin))

        let outcome = try await rig.run(rig.context())

        #expect(outcome == .halted)
        #expect(try tableRowCount(rig.journal, table: "feature") == 0)
        #expect(try tableRowCount(rig.journal, table: "cycle") == 0)
        #expect(try tableRowCount(rig.journal, table: "card") == 0)
        #expect(try tableRowCount(rig.journal, table: "clause") == 0)
        #expect(try tableRowCount(rig.journal, table: "attempt") == 0)
        #expect(try tableRowCount(rig.journal, table: "worktree") == 0)
        #expect(try rig.journal.events(ofType: .featureAuthoringAccepted).isEmpty)

        let event = try #require(try rig.journal.events().first { $0.type == .featureAuthoringHalted })
        guard case .featureAuthoringHalted(let name, let kind, let detail) = event.event else {
            Issue.record("expected featureAuthoringHalted")
            return
        }
        #expect(name == "FEAT-1")
        #expect(kind == "uncitable-definition-of-done")
        #expect(detail?.contains("Uncitable") == true)

        let live = await rig.boards.writing.liveIssues
        let issue = try #require(live.first { $0.title == "FEAT-1" })
        #expect(try await issue.workflowState == waitingOnYouStateID(rig.boards))
        let comments = await rig.boards.writing.comments
        #expect(comments.contains { $0.issue == issue.id && $0.body.contains("Uncitable") })
    }

    @Test("A newly authored Card left with zero clauses is refused, even though the Feature level is citable")
    func thinCardLevelRefusesAuthoring() async throws {
        let kind = try authoringKind()
        let breakdown = FeatureBreakdown(
            definitionOfDone: [authoringClause("The Feature is done.")],
            cards: [
                CardDraft(
                    repository: "backend", kind: kind, title: "Backend one", unitOfWork: "Do it",
                    definitionOfDone: [DefinitionOfDoneClauseDraft(text: "Unreachable", citation: "epic/ghost")]
                )
            ]
        )
        let rig = try await AuthoringRig(drafting: ScriptedBreakdown(breakdown))

        let outcome = try await rig.run(rig.context())

        #expect(outcome == .halted)
        #expect(try tableRowCount(rig.journal, table: "feature") == 0)
        #expect(try tableRowCount(rig.journal, table: "card") == 0)
        let event = try #require(try rig.journal.events().first { $0.type == .featureAuthoringHalted })
        guard case .featureAuthoringHalted(_, let kind, let detail) = event.event else {
            Issue.record("expected featureAuthoringHalted")
            return
        }
        #expect(kind == "uncitable-definition-of-done")
        #expect(detail?.contains("Backend one") == true)
    }

    @Test("A resumed transaction writes every clause row exactly once")
    func resumeWritesClausesExactlyOnce() async throws {
        let rig = try await AuthoringRig()
        let first = try rig.context()
        await #expect(throws: SimulatedCrash.self) {
            _ = try await rig.run(crashing(first, boards: rig.boards, afterApplying: 1))
        }
        #expect(try tableRowCount(rig.journal, table: "clause") == 0)

        let resumed = try rig.context(previous: first)
        let outcome = try await rig.run(resumed)

        #expect(outcome == .authored)
        // One Feature clause, three Card clauses (two backend, one mobile), each c1.
        #expect(try tableRowCount(rig.journal, table: "clause") == 4)

        // finaliseAuthoring is idempotent (a Feature row already exists once written), so replaying the
        // same finished plan — the shape a repeated `resumeUnfinished` call could see — writes nothing a
        // second time.
        let event = try #require(try rig.journal.events(ofType: .featureAuthoringAccepted).first)
        guard case .featureAuthoringAccepted(let plan) = event.event else {
            Issue.record("expected featureAuthoringAccepted")
            return
        }
        let live = await rig.boards.writing.liveIssues
        let feature = try #require(live.first { $0.title == "FEAT-1" })
        let cards = try plan.cards.map { planned in
            AuthoredCardRow(
                issueID: try #require(live.first { $0.title == planned.title }?.id.rawValue),
                repository: planned.repository, kind: planned.kind, order: planned.order, clauses: planned.clauses
            )
        }
        try rig.journal.finaliseAuthoring(
            AuthoredFeature(plan: plan, featureIssueID: feature.id.rawValue, cards: cards),
            runID: resumed.runID, act: .author, nightID: resumed.night.id
        )
        #expect(try tableRowCount(rig.journal, table: "clause") == 4)
    }
}
