import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// roadmap P9.7 (glossary: Refusal; bounds/bound-unanswered-nights): the author Act's Refusal lifecycle
// end to end — RefusalLifecycle advancing the clock at the top of every author Act, AuthoringHalt
// opening/repeating a Refusal on the uncitable-Definition-of-Done halt, and AuthoringTransaction
// resetting a Feature's count on a clean run. Bound arithmetic is exercised with unansweredNightsMax = 1,
// per the roadmap item's done-when. Never asserts model-authored content, only the wiring.

/// A fresh author Act's `ActContext` for one Night, sharing one Journal and one Board across Nights —
/// `makeSelectionContext` (FeatureSelectionFixtures.swift) is fixed to one Night, so this variant takes
/// `nightStart` explicitly.
private func refusalTestContext(
    _ journal: JournalStore, nightStart: NightStart, boards: NightCardTestBoards, previous: RunID? = nil
) throws -> (context: ActContext, runID: RunID) {
    if let previous {
        try journal.releaseActLease(runID: previous)
    }
    let runID = RunID()
    guard case .claimed = try journal.claimActLease(act: .author, runID: runID, mode: .rehearsal) else {
        throw JournalError.actLeaseLost(runID: runID, holder: nil)
    }
    let opening = try journal.openNight(nightStart: nightStart, mode: .rehearsal, act: .author, runID: runID)
    let outbox = Outbox(journal: journal, board: boards.writing, runID: runID, act: .author, nightID: opening.night.id)
    let actBoard = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
    let context = ActContext(
        act: .author, mode: .rehearsal, trigger: .forced, runID: runID, journal: journal,
        night: opening.night, outbox: outbox, board: actBoard, mainlines: selectionMainlines(),
        workspace: nil, repositories: selectionRepositories()
    )
    return (context, runID)
}

@Suite("Refusal lifecycle end to end (P9.7)")
struct RefusalLifecycleTests {
    @Test("""
        unansweredNightsMax = 1: Night 1 opens the Refusal (Waiting on You, comment with content), \
        Night 2 leaves it open with the clock at 1, Night 3 expires it and posts one Blocked update
        """)
    func boundArithmeticAcrossThreeNights() async throws {
        let thin = try authoringBreakdown()
        let thinFeature = FeatureBreakdown(
            definitionOfDone: [DefinitionOfDoneClauseDraft(text: "Uncitable", citation: "epic/ghost")],
            cards: thin.cards
        )
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        let selector = ScriptedFeatureSelector(outcome: .selected(try authoringSelection()))
        let selection = FeatureSelection(
            selector: selector,
            transaction: AuthoringTransaction(
                drafting: ScriptedBreakdown(thinFeature), citations: FakeCitationResolver(),
                transcribing: FakeContractTranscriber(), provenance: FakeProvenanceTester()
            ),
            reselectionsMax: 0
        )
        let authorAct = AuthorAct(predecessorGate: nil, authoring: selection, unansweredNightsMax: 1)

        // Night 1: opens the Refusal.
        let (context1, run1) = try refusalTestContext(
            journal, nightStart: try #require(NightStart(rawValue: "2026-09-15")), boards: boards
        )
        try await authorAct.run(context1)

        var refusal = try #require(try journal.refusals(feature: feature).last)
        #expect(refusal.state == .open)
        #expect(refusal.unansweredNights == 0)
        try await assertOpenedOnBoard(boards, feature: "FEAT-1")
        let issueID = try #require(refusal.issueID)

        // Night 2: still open, the clock at 1.
        let (context2, run2) = try refusalTestContext(
            journal, nightStart: try #require(NightStart(rawValue: "2026-09-16")), boards: boards, previous: run1
        )
        try await authorAct.run(context2)

        refusal = try #require(try journal.refusals(feature: feature).last)
        #expect(refusal.state == .open)
        #expect(refusal.unansweredNights == 1)

        // Night 3: expires — one Blocked / unanswered update, content survives.
        let (context3, _) = try refusalTestContext(
            journal, nightStart: try #require(NightStart(rawValue: "2026-09-17")), boards: boards, previous: run2
        )
        try await authorAct.run(context3)

        refusal = try #require(try journal.refusals(feature: feature).last)
        #expect(refusal.state == .expired)
        #expect(refusal.unansweredNights == 2)
        #expect(refusal.content.contains("Uncitable"))

        let events = try journal.events(ofType: .refusalExpired)
        #expect(events.count == 1)

        let updated = try #require(await boards.writing.liveIssues.first { $0.id.rawValue == issueID })
        #expect(try await updated.workflowState == blockedStateID(boards))
        #expect(updated.labels.contains(try #require(boards.ids["reply overdue"])))
    }

    /// Asserts the Feature Issue landed in Waiting on You with a comment naming the halt's content —
    /// factored out of ``boundArithmeticAcrossThreeNights()`` to keep that test within the length limit.
    private func assertOpenedOnBoard(_ boards: NightCardTestBoards, feature title: String) async throws {
        let issue = try #require(await boards.writing.liveIssues.first { $0.title == title })
        #expect(try await issue.workflowState == waitingOnYouStateID(boards))
        let comments = await boards.writing.comments
        #expect(comments.contains { $0.issue == issue.id && $0.body.contains("Uncitable") })
    }

    @Test("A second author Act in the same Night does not double-count the Refusal's clock")
    func sameNightSecondActDoesNotDoubleCount() async throws {
        let thin = FeatureBreakdown(
            definitionOfDone: [DefinitionOfDoneClauseDraft(text: "Uncitable", citation: "epic/ghost")],
            cards: try authoringBreakdown().cards
        )
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let selector = ScriptedFeatureSelector(outcome: .selected(try authoringSelection()))
        let selection = FeatureSelection(
            selector: selector,
            transaction: AuthoringTransaction(
                drafting: ScriptedBreakdown(thin), citations: FakeCitationResolver(),
                transcribing: FakeContractTranscriber(), provenance: FakeProvenanceTester()
            ),
            reselectionsMax: 0
        )
        let authorAct = AuthorAct(predecessorGate: nil, authoring: selection, unansweredNightsMax: 5)
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))

        let (context1, run1) = try refusalTestContext(
            journal, nightStart: try #require(NightStart(rawValue: "2026-09-15")), boards: boards
        )
        try await authorAct.run(context1)

        let (context2, run2) = try refusalTestContext(
            journal, nightStart: try #require(NightStart(rawValue: "2026-09-16")), boards: boards, previous: run1
        )
        try await authorAct.run(context2)
        try journal.releaseActLease(runID: run2)
        // A second Act of the same Night 2 (a forced re-run) — same nightStart, resumed rather than
        // reopened, mirroring the way NightTests exercises "second Act of the same Night".
        let (context2Again, _) = try refusalTestContext(
            journal, nightStart: try #require(NightStart(rawValue: "2026-09-16")), boards: boards
        )
        try await authorAct.run(context2Again)

        let refusal = try #require(try journal.refusals(feature: feature).last)
        #expect(refusal.unansweredNights == 1)
    }

    @Test("A repeat refusal while open increments the consecutive count without touching the clock")
    func repeatRefusalWhileOpenLeavesClockAlone() async throws {
        let thin = FeatureBreakdown(
            definitionOfDone: [DefinitionOfDoneClauseDraft(text: "Uncitable", citation: "epic/ghost")],
            cards: try authoringBreakdown().cards
        )
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let selector = ScriptedFeatureSelector(outcome: .selected(try authoringSelection()))
        let selection = FeatureSelection(
            selector: selector,
            transaction: AuthoringTransaction(
                drafting: ScriptedBreakdown(thin), citations: FakeCitationResolver(),
                transcribing: FakeContractTranscriber(), provenance: FakeProvenanceTester()
            ),
            reselectionsMax: 0
        )
        let authorAct = AuthorAct(predecessorGate: nil, authoring: selection, unansweredNightsMax: 5)
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))

        let (context1, run1) = try refusalTestContext(
            journal, nightStart: try #require(NightStart(rawValue: "2026-09-15")), boards: boards
        )
        try await authorAct.run(context1)
        let (context2, _) = try refusalTestContext(
            journal, nightStart: try #require(NightStart(rawValue: "2026-09-16")), boards: boards, previous: run1
        )
        try await authorAct.run(context2)

        let refusal = try #require(try journal.refusals(feature: feature).last)
        #expect(refusal.state == .open)
        #expect(refusal.consecutiveRefusals == 2)
        #expect(refusal.unansweredNights == 1)
        #expect(refusal.openedNightID == context1.night.id)
    }

    @Test("Clean authoring resets only that Feature's count and closes its open Refusal without answering it")
    func cleanAuthoringResetsCount() async throws {
        let thin = FeatureBreakdown(
            definitionOfDone: [DefinitionOfDoneClauseDraft(text: "Uncitable", citation: "epic/ghost")],
            cards: try authoringBreakdown().cards
        )
        let clean = try authoringBreakdown()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))

        let selector1 = ScriptedFeatureSelector(outcome: .selected(try authoringSelection()))
        let selection1 = FeatureSelection(
            selector: selector1,
            transaction: AuthoringTransaction(
                drafting: ScriptedBreakdown(thin), citations: FakeCitationResolver(),
                transcribing: FakeContractTranscriber(), provenance: FakeProvenanceTester()
            ),
            reselectionsMax: 0
        )
        let (context1, run1) = try refusalTestContext(
            journal, nightStart: try #require(NightStart(rawValue: "2026-09-15")), boards: boards
        )
        try await AuthorAct(predecessorGate: nil, authoring: selection1, unansweredNightsMax: 5).run(context1)
        #expect(try journal.consecutiveRefusals(feature: feature) == 1)

        let selector2 = ScriptedFeatureSelector(outcome: .selected(try authoringSelection()))
        let selection2 = FeatureSelection(
            selector: selector2,
            transaction: AuthoringTransaction(
                drafting: ScriptedBreakdown(clean), citations: FakeCitationResolver(),
                transcribing: FakeContractTranscriber(), provenance: FakeProvenanceTester()
            ),
            reselectionsMax: 0
        )
        let (context2, _) = try refusalTestContext(
            journal, nightStart: try #require(NightStart(rawValue: "2026-09-16")), boards: boards, previous: run1
        )
        try await AuthorAct(predecessorGate: nil, authoring: selection2, unansweredNightsMax: 5).run(context2)

        let refusal = try #require(try journal.refusals(feature: feature).last)
        #expect(refusal.state == .open)
        #expect(refusal.closedNightID != nil)
        #expect(refusal.consecutiveRefusals == 0)
        #expect(try journal.events(ofType: .refusalCountReset).count == 1)
    }

    @Test("A re-refusal after expiry writes nothing to the board")
    func reRefusalAfterExpiryWritesNothingToBoard() async throws {
        let thin = FeatureBreakdown(
            definitionOfDone: [DefinitionOfDoneClauseDraft(text: "Uncitable", citation: "epic/ghost")],
            cards: try authoringBreakdown().cards
        )
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        let selected = try authoringSelection()

        func act() -> AuthorAct {
            let selector = ScriptedFeatureSelector(outcome: .selected(selected))
            let selection = FeatureSelection(
                selector: selector,
                transaction: AuthoringTransaction(
                    drafting: ScriptedBreakdown(thin), citations: FakeCitationResolver(),
                    transcribing: FakeContractTranscriber(), provenance: FakeProvenanceTester()
                ),
                reselectionsMax: 0
            )
            return AuthorAct(predecessorGate: nil, authoring: selection, unansweredNightsMax: 1)
        }

        let (context1, run1) = try refusalTestContext(
            journal, nightStart: try #require(NightStart(rawValue: "2026-09-15")), boards: boards
        )
        try await act().run(context1)
        let (context2, run2) = try refusalTestContext(
            journal, nightStart: try #require(NightStart(rawValue: "2026-09-16")), boards: boards, previous: run1
        )
        try await act().run(context2)
        let (context3, run3) = try refusalTestContext(
            journal, nightStart: try #require(NightStart(rawValue: "2026-09-17")), boards: boards, previous: run2
        )
        try await act().run(context3)
        let refusal = try #require(try journal.refusals(feature: feature).last)
        #expect(refusal.state == .expired)

        let commentCountBefore = await boards.writing.comments.count
        let (context4, _) = try refusalTestContext(
            journal, nightStart: try #require(NightStart(rawValue: "2026-09-18")), boards: boards, previous: run3
        )
        try await act().run(context4)

        let refusalAfter = try #require(try journal.refusals(feature: feature).last)
        #expect(refusalAfter.state == .expired)
        // Night 3 already re-refused once (this Feature halts every Night), taking the count to 3;
        // Night 4's re-refusal after expiry takes it to 4 — the assertion that matters here is that it
        // still moved (the halt still records the Refusal), while the board saw nothing new.
        #expect(refusalAfter.consecutiveRefusals == 4)
        let commentCountAfter = await boards.writing.comments.count
        #expect(commentCountAfter == commentCountBefore)
    }

    @Test("A non-uncitable halt (repositoriesUndetermined) creates no Refusal row")
    func nonUncitableHaltCreatesNoRefusal() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        let selected = SelectedFeature(
            name: feature, reasoning: "no repos determined", sequence: nil, repositories: [], adoptedCardIssueIDs: []
        )
        let selector = ScriptedFeatureSelector(outcome: .selected(selected))
        let selection = FeatureSelection(selector: selector, reselectionsMax: 0)
        let (context, _) = try refusalTestContext(
            journal, nightStart: try #require(NightStart(rawValue: "2026-09-15")), boards: boards
        )

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .halted)
        #expect(try journal.refusals(feature: feature).isEmpty)
    }
}

/// The Blocked workflow state's id, mirroring `waitingOnYouStateID` (FeatureSelectionFixtures.swift).
func blockedStateID(_ boards: NightCardTestBoards) async throws -> BoardObjectID {
    let states = try await boards.provisioning.workflowStates(team: teamID)
    guard let id = states.first(where: { $0.name == "Blocked" })?.id else {
        Issue.record("Blocked state was not seeded")
        return BoardObjectID(rawValue: "missing")
    }
    return id
}
