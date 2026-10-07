import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// roadmap P9.3: feature selection's own validation, recording and dispatch to the transaction. The
// model-authored judgement (``FeatureSelecting``) is opaque scripted data here — these tests assert
// only that ``FeatureSelection`` records it, validates it against this Project's own configuration,
// and routes it, never anything about the quality of a selection. Halt paths and configuration errors
// are FeatureSelectionHaltTests.swift; shared fixtures are FeatureSelectionFixtures.swift.

@Suite("Feature selection (P9.3)")
struct FeatureSelectionTests {
    @Test("A selected Feature is recorded, validated and handed to the transaction once")
    func selectedFeatureIsRecordedValidatedAndAuthored() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let repositories = selectionRepositories()
        let selected = SelectedFeature(
            name: try #require(FeatureName(rawValue: "FEAT-1")),
            reasoning: "Splits the seam cleanly.",
            sequence: FeatureSequence(precededBy: "FEAT-0", followedBy: "FEAT-2", seam: "the endpoint contract"),
            repositories: ["mobile", "backend"],
            adoptedCardIssueIDs: ["BACK-1"]
        )
        let (_, cycleID) = try insertFeatureSelectionAdoptionFixture(journal, closedFeatureIssueID: "OLD-1")
        try insertFeatureSelectionAdoptionCard(
            journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend", order: 1
        )
        try insertFeatureSelectionAdoptionCard(
            journal, cycleID: cycleID, issueID: "BACK-2", repository: "backend", order: 2
        )

        let selector = ScriptedFeatureSelector(outcome: .selected(selected))
        let transaction = ScriptedSelectedFeatureAuthoring()
        let selection = FeatureSelection(selector: selector, transaction: transaction)
        let (context, _) = try makeSelectionContext(journal, repositories: repositories)

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .authored)
        #expect(selector.callCount == 1)
        #expect(transaction.callCount == 1)
        let handed = try #require(transaction.lastSelection)
        #expect(handed.repositories == ["backend", "mobile"])
        #expect(handed.adoptedCardIssueIDs == ["BACK-1"])

        let events = try journal.events()
        let event = try #require(events.first { $0.type == .featureSelected })
        guard case .featureSelected(let payload) = event.event else {
            Issue.record("expected featureSelected")
            return
        }
        #expect(payload.name == "FEAT-1")
        #expect(payload.reasoning == "Splits the seam cleanly.")
        #expect(payload.precededBy == "FEAT-0")
        #expect(payload.followedBy == "FEAT-2")
        #expect(payload.seam == "the endpoint contract")
        #expect(payload.repositories == ["backend", "mobile"])
        #expect(payload.adoptedCardIssueIDs == ["BACK-1"])
        #expect(payload.unadoptedCardIssueIDs == ["BACK-2"])
    }

    @Test("The request carries the spec source, repos with Repo Roles, mainlines and the named Feature")
    func requestCarriesEverythingTheSelectorNeeds() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let repositories = selectionRepositories()
        let selector = ScriptedFeatureSelector(outcome: .noSelectableFeature)
        let selection = FeatureSelection(selector: selector)
        let featureName = try #require(FeatureName(rawValue: "FORCED-1"))
        let (context, _) = try makeSelectionContext(
            journal, repositories: repositories, trigger: .forcedForFeature(featureName)
        )

        _ = try await selection.selectAndAuthor(context)

        let request = try #require(selector.lastRequest)
        #expect(request.specificationSource == .specSource(SpecSource(path: "/repos/spec")))
        #expect(Set(request.repos.map(\.name)) == ["backend", "mobile"])
        #expect(request.repos.first { $0.name == "backend" }?.role == .backend)
        #expect(request.repos.first { $0.name == "mobile" }?.role == .mobile)
        #expect(request.namedFeature == featureName)
        #expect(request.mainlines.workingRepos["backend"] != nil)
    }

    @Test("A forced name the selector ignores throws namedFeatureIgnored; nothing is recorded as selected")
    func forcedNameIgnoredThrows() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let repositories = selectionRepositories()
        let selected = SelectedFeature(
            name: try #require(FeatureName(rawValue: "OTHER")), reasoning: "not what was forced",
            sequence: nil, repositories: ["backend"], adoptedCardIssueIDs: []
        )
        let selector = ScriptedFeatureSelector(outcome: .selected(selected))
        let selection = FeatureSelection(selector: selector)
        let forced = try #require(FeatureName(rawValue: "FORCED-1"))
        let (context, _) = try makeSelectionContext(
            journal, repositories: repositories, trigger: .forcedForFeature(forced)
        )

        await #expect(throws: FeatureSelectionError.self) {
            try await selection.selectAndAuthor(context)
        }
        let events = try journal.events().map(\.type)
        #expect(!events.contains(.featureSelected))
    }

    @Test("A Shelved Card named as adopted is dropped, and a non-candidate id is dropped")
    func nonCandidateAdoptionIsDropped() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let repositories = selectionRepositories()
        let (_, cycleID) = try insertFeatureSelectionAdoptionFixture(journal, closedFeatureIssueID: "OLD-1")
        try journal.write { db in
            try db.execute(
                sql: """
                INSERT INTO card
                    (cycle_id, issue_id, repository, kind, authored_order, state, budget_epoch, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    cycleID, "BACK-3", "backend", "card", 3, CardState.shelved.rawValue, 0,
                    JournalStore.timestamp(Date())
                ]
            )
        }
        let selected = SelectedFeature(
            name: try #require(FeatureName(rawValue: "FEAT-1")), reasoning: "adopts what it can",
            sequence: nil, repositories: ["backend"],
            adoptedCardIssueIDs: ["BACK-3", "NOT-A-CANDIDATE"]
        )
        let selector = ScriptedFeatureSelector(outcome: .selected(selected))
        let transaction = ScriptedSelectedFeatureAuthoring()
        let selection = FeatureSelection(selector: selector, transaction: transaction)
        let (context, _) = try makeSelectionContext(journal, repositories: repositories)

        _ = try await selection.selectAndAuthor(context)

        let handed = try #require(transaction.lastSelection)
        #expect(handed.adoptedCardIssueIDs.isEmpty)
    }

    @Test("No selectable Feature: noWorkAvailable, no selection event recorded, transaction never called")
    func noSelectableFeatureYieldsNoWorkAvailable() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let repositories = selectionRepositories()
        let selector = ScriptedFeatureSelector(outcome: .noSelectableFeature)
        let transaction = ScriptedSelectedFeatureAuthoring()
        let selection = FeatureSelection(selector: selector, transaction: transaction)
        let (context, _) = try makeSelectionContext(journal, repositories: repositories)

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .noWorkAvailable)
        #expect(transaction.callCount == 0)
        let events = try journal.events().map(\.type)
        #expect(!events.contains(.featureSelected))
    }

    @Test("Through AuthorAct, noSelectableFeature records the idle verdict")
    func throughAuthorActNoSelectableFeatureRecordsIdleVerdict() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let selector = ScriptedFeatureSelector(outcome: .noSelectableFeature)
        let selection = FeatureSelection(selector: selector)

        let invocation = EngineInvocation(
            act: .author, mode: .rehearsal, nightStart: featureSelectionNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, repositories: selectionRepositories(),
            work: AuthorAct(predecessorGate: nil, authoring: selection).work
        )
        try await invocation.run()

        let events = try journal.events().map(\.type)
        #expect(events.contains(.authoringNoWorkAvailable))
        #expect(try journal.currentNight()?.verdict == .idle)
    }
}
