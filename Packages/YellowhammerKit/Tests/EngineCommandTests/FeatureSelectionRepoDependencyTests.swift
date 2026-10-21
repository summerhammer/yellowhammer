import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// feature-authoring/select-the-next-feature, `#repo-dependency-halt`: a selected Feature that touches both
// ends of a declared Repo Dependency halts before `featureSelected` is recorded and before anything is
// authored. Shared fixtures are FeatureSelectionFixtures.swift.

private func dependencyRepositories(
    backendConsumes: [RepoDependency] = [RepoDependency(producer: "contracts", via: .tag)],
    mobileConsumes: [RepoDependency] = []
) -> ProjectRepositories {
    ProjectRepositories(
        workingRepos: [
            Repo(name: "backend", path: "/repos/backend", role: .backend, consumes: backendConsumes),
            Repo(name: "mobile", path: "/repos/mobile", role: .mobile, consumes: mobileConsumes),
            Repo(name: "contracts", path: "/repos/contracts", role: .backend)
        ],
        specSource: SpecSource(path: "/repos/spec")
    )
}

private func feature(_ repositories: [String]) throws -> SelectedFeature {
    SelectedFeature(
        name: try #require(FeatureName(rawValue: "FEAT-1")), reasoning: "spans", sequence: nil,
        repositories: repositories, adoptedCardIssueIDs: []
    )
}

@Suite("Feature selection halts on a Feature that spans a Repo Dependency")
struct FeatureSelectionRepoDependencyTests {
    @Test("A Feature touching both ends of an edge halts, names the edge and the upstream-first split")
    func spanningFeatureHalts() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let transaction = ScriptedSelectedFeatureAuthoring()
        let selection = FeatureSelection(
            selector: ScriptedFeatureSelector(outcome: .selected(try feature(["backend", "contracts"]))),
            transaction: transaction
        )
        let (context, _) = try makeSelectionContext(journal, repositories: dependencyRepositories(), boards: boards)

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .halted)
        #expect(transaction.callCount == 0)
        let events = try journal.events()
        #expect(!events.contains { $0.type == .featureSelected })
        let event = try #require(events.first { $0.type == .featureAuthoringHalted })
        guard case .featureAuthoringHalted(let name, let kind, let detail) = event.event else {
            Issue.record("expected featureAuthoringHalted")
            return
        }
        #expect(name == "FEAT-1")
        #expect(kind == "feature-spans-repo-dependency")
        #expect(detail == "backend->contracts(tag)")

        let issue = try #require(await boards.writing.liveIssues.first { $0.title == "FEAT-1" })
        #expect(try await issue.workflowState == waitingOnYouStateID(boards))
        let comments = await boards.writing.comments
        let comment = try #require(comments.first { $0.issue == issue.id })
        #expect(comment.body.contains("This Feature spans a declared Repo Dependency"))
        #expect(comment.body.contains("backend → contracts (via tag)"))
        #expect(comment.body.contains("author the producer side (contracts) as its own Feature first"))
        #expect(comment.body.contains("the consumer work (backend) follows in a later Feature"))
        #expect(comment.body.contains("Force a narrower Feature to clear this halt."))
    }

    @Test("The same Feature with the edge removed is authored")
    func withoutTheEdgeItIsAuthored() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let transaction = ScriptedSelectedFeatureAuthoring()
        let selection = FeatureSelection(
            selector: ScriptedFeatureSelector(outcome: .selected(try feature(["backend", "contracts"]))),
            transaction: transaction
        )
        let (context, _) = try makeSelectionContext(
            journal, repositories: dependencyRepositories(backendConsumes: []), boards: boards
        )

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .authored)
        #expect(transaction.callCount == 1)
    }

    @Test("Forcing the Feature by name is checked the same way and still halts")
    func forcedFeatureStillHalts() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let transaction = ScriptedSelectedFeatureAuthoring()
        let selected = try feature(["backend", "contracts"])
        let selection = FeatureSelection(
            selector: ScriptedFeatureSelector(outcome: .selected(selected)), transaction: transaction
        )
        let (context, _) = try makeSelectionContext(
            journal, repositories: dependencyRepositories(), boards: boards,
            trigger: .forcedForFeature(selected.name)
        )

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .halted)
        #expect(transaction.callCount == 0)
        #expect(try journal.events().contains { $0.type == .featureAuthoringHalted })
    }

    @Test("A Feature touching only the consumer is authored, edge or not")
    func consumerOnlyFeatureIsAuthored() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let transaction = ScriptedSelectedFeatureAuthoring()
        let selection = FeatureSelection(
            selector: ScriptedFeatureSelector(outcome: .selected(try feature(["backend"]))),
            transaction: transaction
        )
        let (context, _) = try makeSelectionContext(journal, repositories: dependencyRepositories(), boards: boards)

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .authored)
        #expect(transaction.callCount == 1)
    }

    @Test("Every spanning edge is named, in the consumers' file order")
    func everySpanningEdgeIsNamed() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let transaction = ScriptedSelectedFeatureAuthoring()
        let selection = FeatureSelection(
            selector: ScriptedFeatureSelector(outcome: .selected(try feature(["backend", "contracts", "mobile"]))),
            transaction: transaction
        )
        let repositories = dependencyRepositories(
            mobileConsumes: [
                RepoDependency(producer: "backend", via: .mainline),
                RepoDependency(producer: "contracts", via: .tag)
            ]
        )
        let (context, _) = try makeSelectionContext(journal, repositories: repositories, boards: boards)

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .halted)
        let event = try #require(try journal.events().first { $0.type == .featureAuthoringHalted })
        guard case .featureAuthoringHalted(_, _, let detail) = event.event else {
            Issue.record("expected featureAuthoringHalted")
            return
        }
        #expect(detail == "backend->contracts(tag); mobile->backend(mainline); mobile->contracts(tag)")
    }

    @Test("Only direct edges span: A → B and B → C, with a Feature touching A and C, is not chained")
    func chainedEdgesDoNotSpan() {
        let repos = [
            Repo(name: "a", path: "/a", role: .backend, consumes: [RepoDependency(producer: "b", via: .tag)]),
            Repo(name: "b", path: "/b", role: .backend, consumes: [RepoDependency(producer: "c", via: .tag)]),
            Repo(name: "c", path: "/c", role: .backend)
        ]
        #expect(FeatureSelection.spanningEdges(repos, selected: ["a", "c"]).isEmpty)
        #expect(
            FeatureSelection.spanningEdges(repos, selected: ["a", "b", "c"])
                == [
                    SpannedRepoDependency(consumer: "a", producer: "b", via: .tag),
                    SpannedRepoDependency(consumer: "b", producer: "c", via: .tag)
                ]
        )
    }

    @Test("A Feature touching a consumer the release gate holds is held: nothing selected, nothing authored")
    func heldConsumerFeatureIsHeld() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let transaction = ScriptedSelectedFeatureAuthoring()
        let selector = ScriptedFeatureSelector(outcome: .selected(try feature(["backend"])))
        let gate = ScriptedReleaseGate(held: [heldBackend])
        let selection = FeatureSelection(selector: selector, transaction: transaction, releaseGate: gate)
        let (context, _) = try makeSelectionContext(journal, repositories: dependencyRepositories(), boards: boards)

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .releaseGateHeld)
        #expect(transaction.callCount == 0)
        #expect(selector.lastRequest?.heldConsumers == [heldBackend])
        let events = try journal.events()
        #expect(!events.contains { $0.type == .featureSelected })
        #expect(events.filter { $0.type == .authoringReleaseGateHeld }.map(\.event) == [
            .authoringReleaseGateHeld(
                featureName: "FEAT-1", consumer: "backend", producer: "contracts", producerFeatureIssueID: "FEAT-K",
                hold: .awaitingRelease
            )
        ])
    }

    @Test("A Feature touching only the producer is authored while the consumer is held")
    func producerOnlyFeatureIsAuthored() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let transaction = ScriptedSelectedFeatureAuthoring()
        let selection = FeatureSelection(
            selector: ScriptedFeatureSelector(outcome: .selected(try feature(["contracts"]))),
            transaction: transaction, releaseGate: ScriptedReleaseGate(held: [heldBackend])
        )
        let (context, _) = try makeSelectionContext(journal, repositories: dependencyRepositories(), boards: boards)

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .authored)
        #expect(transaction.callCount == 1)
        #expect(try !journal.events().contains { $0.type == .authoringReleaseGateHeld })
    }

    @Test("A Feature that spans the edge and touches the held consumer halts on the seam first")
    func seamHaltWinsOverTheGate() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBuildActBoards()
        let transaction = ScriptedSelectedFeatureAuthoring()
        let selection = FeatureSelection(
            selector: ScriptedFeatureSelector(outcome: .selected(try feature(["backend", "contracts"]))),
            transaction: transaction, releaseGate: ScriptedReleaseGate(held: [heldBackend])
        )
        let (context, _) = try makeSelectionContext(journal, repositories: dependencyRepositories(), boards: boards)

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .halted)
        #expect(transaction.callCount == 0)
        #expect(try !journal.events().contains { $0.type == .authoringReleaseGateHeld })
    }
}

private let heldBackend = HeldConsumer(
    consumer: "backend", producer: "contracts", producerFeature: "FEAT-K", producerFeatureIssueID: "FEAT-K"
)

private struct ScriptedReleaseGate: ReleaseGate {
    let held: [HeldConsumer]

    func heldConsumers(_ context: ActContext) async throws -> [HeldConsumer] { held }
}
