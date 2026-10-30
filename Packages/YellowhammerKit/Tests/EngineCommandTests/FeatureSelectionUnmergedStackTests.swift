import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// roadmap P23.2 (spec: feature-authoring/select-the-next-feature, `#effective-base`): selection is told every
// Feature in the Unmerged Feature Stack U, never selects one of them again, and holds a consumer of a producer
// with a Feature in U. Shared fixtures are FeatureSelectionFixtures.swift and PredecessorAncestryGateFixtures.swift.

private let stackRepositories = ProjectRepositories(
    workingRepos: [
        Repo(name: "backend", path: "/repos/backend", role: .backend),
        Repo(
            name: "mobile", path: "/repos/mobile", role: .mobile,
            consumes: [RepoDependency(producer: "backend", via: .mainline)]
        )
    ],
    specSource: SpecSource(path: "/repos/spec")
)

/// Seeds F1 "Add login" in U — archived, pushed in `backend` on `yh-f1`, no Observed Merge — with the
/// `featureAuthored` event its name is read from.
private func seedAddLoginInU(_ journal: JournalStore, runID: RunID) throws {
    let featureID = try insertGateFeature(
        journal, issueID: "FEAT-1", branch: "yh-f1", repositories: ["backend"], landed: true,
        pushedTips: ["backend": "c1"]
    )
    try journal.append(
        .featureAuthored(FeatureAuthoredPayload(
            name: "Add login", groupKey: "authoring:Add login:0", featureIssueID: "FEAT-1",
            cycleID: try gateCycleID(journal, featureID: featureID), cardCount: 1, adoptedCount: 0
        )),
        act: .author, runID: runID
    )
}

private func selected(_ name: String, repositories: [String]) throws -> SelectedFeature {
    SelectedFeature(
        name: try #require(FeatureName(rawValue: name)), reasoning: "next", sequence: nil,
        repositories: repositories, adoptedCardIssueIDs: []
    )
}

@Suite("Feature selection and the Unmerged Feature Stack")
struct FeatureSelectionUnmergedStackTests {
    @Test("The selection request lists F1 as awaiting merge, with its repositories and branch")
    func requestListsTheStack() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let (context, runID) = try makeSelectionContext(journal, repositories: stackRepositories, boards: boards)
        try seedAddLoginInU(journal, runID: runID)
        let selector = ScriptedFeatureSelector(outcome: .noSelectableFeature)

        _ = try await FeatureSelection(selector: selector).selectAndAuthor(context)

        let listed = try #require(selector.lastRequest?.boardState.unmergedFeatures)
        #expect(listed.map(\.name) == ["Add login"])
        #expect(listed.first?.touchedRepositories == ["backend"])
        #expect(listed.first?.unmergedBranches == [
            SelectionBoardState.UnmergedBranch(repository: "backend", branch: "yh-f1")
        ])
    }

    @Test("Selecting a Feature in U again is an authoring fault: nothing selected, nothing authored")
    func reselectingAFeatureInUIsRefused() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let (context, runID) = try makeSelectionContext(journal, repositories: stackRepositories, boards: boards)
        try seedAddLoginInU(journal, runID: runID)
        let transaction = ScriptedSelectedFeatureAuthoring()
        let selection = FeatureSelection(
            selector: ScriptedFeatureSelector(outcome: .selected(try selected("add LOGIN", repositories: ["backend"]))),
            transaction: transaction
        )

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .authoringRolledBack)
        #expect(transaction.callCount == 0)
        let events = try journal.events()
        #expect(!events.contains { $0.type == .featureSelected })
        #expect(!events.contains { $0.type == .featureAuthoringHalted })
        let failure = try #require(events.first { $0.type == .featureSelectionFailed }?.event)
        guard case .featureSelectionFailed(let reason) = failure else {
            Issue.record("expected featureSelectionFailed")
            return
        }
        #expect(reason.contains("'add LOGIN'"))
        #expect(reason.contains("awaits merge in backend"))
    }

    @Test("A Feature not in U is selected and handed to the transaction as before")
    func anotherFeatureIsAuthored() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let (context, runID) = try makeSelectionContext(journal, repositories: stackRepositories, boards: boards)
        try seedAddLoginInU(journal, runID: runID)
        let transaction = ScriptedSelectedFeatureAuthoring()
        let selection = FeatureSelection(
            selector: ScriptedFeatureSelector(
                outcome: .selected(try selected("Add logout", repositories: ["backend"]))
            ),
            transaction: transaction
        )

        _ = try await selection.selectAndAuthor(context)

        #expect(transaction.callCount == 1)
        #expect(try !journal.events().contains { $0.type == .featureSelectionFailed })
    }

    @Test("A Feature touching a mainline consumer of backend is held on F1's merge: a quiet Night")
    func consumerOfAnUnmergedProducerIsHeld() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let (context, runID) = try makeSelectionContext(journal, repositories: stackRepositories, boards: boards)
        try seedAddLoginInU(journal, runID: runID)
        let transaction = ScriptedSelectedFeatureAuthoring()
        let selector = ScriptedFeatureSelector(
            outcome: .selected(try selected("Mobile login", repositories: ["mobile"]))
        )
        let selection = FeatureSelection(
            selector: selector, transaction: transaction, releaseGate: ObservedReleaseGate()
        )

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .releaseGateHeld)
        #expect(transaction.callCount == 0)
        #expect(selector.lastRequest?.heldConsumers.map(\.hold) == [.awaitingMerge])
        #expect(try journal.events().filter { $0.type == .authoringReleaseGateHeld }.map(\.event) == [
            .authoringReleaseGateHeld(
                featureName: "Mobile login", consumer: "mobile", producer: "backend",
                producerFeatureIssueID: "FEAT-1", hold: .awaitingMerge
            )
        ])
    }
}
