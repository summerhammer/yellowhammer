import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// roadmap P9.3: the halt paths (no backward-compatible seam, undetermined repositories, a repository
// outside this Project) and the Project-configuration errors feature selection refuses to guess past.
// A halt is recorded durably before any board write, then routed to Waiting on You naming the reason;
// it allocates no Worktree, dispatches nothing and records no Attempt. Shared fixtures are
// FeatureSelectionFixtures.swift; the selection/validation tests are FeatureSelectionTests.swift.

@Suite("Feature selection halts and configuration errors (P9.3)")
struct FeatureSelectionHaltTests {
    @Test("A selector-reported seam halt is recorded, routed to Waiting on You, and authors nothing")
    func selectorHaltIsRecordedAndRouted() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        let selector = ScriptedFeatureSelector(
            outcome: .halted(feature: feature, cause: .noBackwardCompatibleSeam(seam: "the shared endpoint"))
        )
        let transaction = ScriptedSelectedFeatureAuthoring()
        let workspace = ReconcilerFakeWorkspace()
        let selection = FeatureSelection(selector: selector, transaction: transaction)
        let (context, _) = try makeSelectionContext(
            journal, repositories: selectionRepositories(), boards: boards, workspace: workspace
        )

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .halted)
        #expect(transaction.callCount == 0)
        #expect(workspace.listCalls == 0)
        #expect(workspace.removeCalls.isEmpty)
        #expect(try tableRowCount(journal, table: "worktree") == 0)
        #expect(try tableRowCount(journal, table: "attempt") == 0)

        let events = try journal.events()
        let event = try #require(events.first { $0.type == .featureAuthoringHalted })
        guard case .featureAuthoringHalted(let name, let kind, let detail) = event.event else {
            Issue.record("expected featureAuthoringHalted")
            return
        }
        #expect(name == "FEAT-1")
        #expect(kind == "no-backward-compatible-seam")
        #expect(detail == "the shared endpoint")

        let issue = try #require(await boards.writing.liveIssues.first { $0.title == "FEAT-1" })
        #expect(try await issue.workflowState == waitingOnYouStateID(boards))
        #expect(issue.labels.contains(try #require(boards.ids["Feature"])))
        let comments = await boards.writing.comments
        #expect(comments.contains { $0.issue == issue.id && $0.body.contains("the shared endpoint") })
    }

    @Test("Empty repositories halt as repositoriesUndetermined")
    func emptyRepositoriesHalt() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let selected = SelectedFeature(
            name: try #require(FeatureName(rawValue: "FEAT-1")), reasoning: "no repos determined",
            sequence: nil, repositories: [], adoptedCardIssueIDs: []
        )
        let selector = ScriptedFeatureSelector(outcome: .selected(selected))
        let transaction = ScriptedSelectedFeatureAuthoring()
        let selection = FeatureSelection(selector: selector, transaction: transaction)
        let (context, _) = try makeSelectionContext(journal, repositories: selectionRepositories(), boards: boards)

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .halted)
        #expect(transaction.callCount == 0)
        let event = try #require(try journal.events().first { $0.type == .featureAuthoringHalted })
        guard case .featureAuthoringHalted(_, let kind, let detail) = event.event else {
            Issue.record("expected featureAuthoringHalted")
            return
        }
        #expect(kind == "repositories-undetermined")
        #expect(detail == nil)
        let issue = try #require(await boards.writing.liveIssues.first { $0.title == "FEAT-1" })
        #expect(try await issue.workflowState == waitingOnYouStateID(boards))
    }

    @Test("A repository outside this Project halts as contractOutsideProject, naming it")
    func repositoryOutsideProjectHalts() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let selected = SelectedFeature(
            name: try #require(FeatureName(rawValue: "FEAT-1")), reasoning: "touches a ghost repo",
            sequence: nil, repositories: ["backend", "ghost"], adoptedCardIssueIDs: []
        )
        let selector = ScriptedFeatureSelector(outcome: .selected(selected))
        let transaction = ScriptedSelectedFeatureAuthoring()
        let selection = FeatureSelection(selector: selector, transaction: transaction)
        let (context, _) = try makeSelectionContext(journal, repositories: selectionRepositories(), boards: boards)

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .halted)
        #expect(transaction.callCount == 0)
        let event = try #require(try journal.events().first { $0.type == .featureAuthoringHalted })
        guard case .featureAuthoringHalted(_, let kind, let detail) = event.event else {
            Issue.record("expected featureAuthoringHalted")
            return
        }
        #expect(kind == "contract-outside-project")
        #expect(detail == "ghost")
        let comments = await boards.writing.comments
        #expect(comments.contains { $0.body.contains("ghost") })
    }

    @Test("Halting twice on the same Feature reuses the same create client id: no duplicate issue")
    func repeatedHaltIsIdempotent() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))

        for _ in 0..<2 {
            let selector = ScriptedFeatureSelector(
                outcome: .halted(feature: feature, cause: .repositoriesUndetermined)
            )
            let selection = FeatureSelection(selector: selector)
            let (context, runID) = try makeSelectionContext(
                journal, repositories: selectionRepositories(), boards: boards
            )
            _ = try await selection.selectAndAuthor(context)
            try journal.releaseActLease(runID: runID)
        }

        let issues = await boards.writing.liveIssues.filter { $0.title == "FEAT-1" }
        #expect(issues.count == 1)
        let events = try journal.events(ofType: .featureAuthoringHalted)
        #expect(events.count == 2)
    }

    @Test("No repositories configured throws noRepositoriesConfigured; the selector is never called")
    func noRepositoriesConfiguredThrows() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let selector = ScriptedFeatureSelector(outcome: .noSelectableFeature)
        let selection = FeatureSelection(selector: selector)
        let (context, _) = try makeSelectionContext(journal, repositories: nil)

        await #expect(throws: FeatureSelectionError.self) {
            try await selection.selectAndAuthor(context)
        }
        #expect(selector.callCount == 0)
    }

    @Test("No specification source configured throws noSpecificationSource; the selector is never called")
    func noSpecificationSourceThrows() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let repositories = ProjectRepositories(
            workingRepos: [Repo(name: "backend", path: "/repos/backend", role: .backend)]
        )
        let selector = ScriptedFeatureSelector(outcome: .noSelectableFeature)
        let selection = FeatureSelection(selector: selector)
        let (context, _) = try makeSelectionContext(journal, repositories: repositories)

        await #expect(throws: FeatureSelectionError.self) {
            try await selection.selectAndAuthor(context)
        }
        #expect(selector.callCount == 0)
    }

    @Test("Multiple specification sources throws multipleSpecificationSources; the selector is never called")
    func multipleSpecificationSourcesThrows() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let repositories = selectionRepositories(includeSpecWorkingRepo: true)
        let selector = ScriptedFeatureSelector(outcome: .noSelectableFeature)
        let selection = FeatureSelection(selector: selector)
        let (context, _) = try makeSelectionContext(journal, repositories: repositories)

        await #expect(throws: FeatureSelectionError.self) {
            try await selection.selectAndAuthor(context)
        }
        #expect(selector.callCount == 0)
    }

    @Test("Through AuthorAct, a halt returns normally and the Night Card names it")
    func throughAuthorActHaltIsQuiet() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let board = ActBoard(reading: FakeReadingBoard([]), writing: boards.writing, provisioning: boards.provisioning)
        let feature = try #require(FeatureName(rawValue: "FEAT-1"))
        let selector = ScriptedFeatureSelector(
            outcome: .halted(feature: feature, cause: .repositoriesUndetermined)
        )
        let selection = FeatureSelection(selector: selector)

        let invocation = EngineInvocation(
            act: .author, mode: .rehearsal, nightStart: featureSelectionNightStart, journal: journal,
            trigger: .forced, runID: RunID(), board: board, repositories: selectionRepositories(),
            work: AuthorAct(predecessorGate: nil, authoring: selection).work
        )
        try await invocation.run()

        let events = try journal.events().map(\.type)
        #expect(events.contains(.featureAuthoringHalted))
        #expect(events.last == .actEnded)

        let card = try #require(await boards.writing.liveIssues.first { $0.title.hasPrefix("Night") })
        let description = try #require(card.description)
        #expect(description.contains("FEAT-1"))
    }
}
