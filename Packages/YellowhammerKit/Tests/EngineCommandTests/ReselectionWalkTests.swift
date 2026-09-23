import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Synchronization
import Testing

// roadmap P11.6 (spec: feature-authoring/select-the-next-feature; bounds/overview): the
// re-selection walk `FeatureSelection.selectAndAuthor` runs when a selection is refused — depth 0 is the
// first selection, a Refusal at depth < reselectionsMax re-selects, naming every Feature refused earlier
// this Night to the selector; a Refusal at depth == reselectionsMax ends the walk. Bound arithmetic only
// — nothing here asserts model-authored content. Shared fixtures live in FeatureSelectionFixtures.swift.

/// A `FeatureSelecting` that answers one outcome per call, in order, recording every request it saw.
/// `.noSelectableFeature` once its scripted outcomes are exhausted.
final class SequencedFeatureSelector: FeatureSelecting, Sendable {
    private struct State {
        var requests: [FeatureSelectionRequest] = []
    }
    private let state = Mutex(State())
    private let outcomes: [FeatureSelectionOutcome]

    init(outcomes: [FeatureSelectionOutcome]) {
        self.outcomes = outcomes
    }

    var callCount: Int { state.withLock { $0.requests.count } }
    var requests: [FeatureSelectionRequest] { state.withLock { $0.requests } }

    func select(_ request: FeatureSelectionRequest, context: ActContext) async throws -> FeatureSelectionOutcome {
        let index = state.withLock { box -> Int in
            box.requests.append(request)
            return box.requests.count - 1
        }
        guard index < outcomes.count else { return .noSelectableFeature }
        return outcomes[index]
    }
}

/// A `SelectedFeatureAuthoring` that refuses every Feature named in `refuse` and authors every other
/// one cleanly, recording each call's Feature name and the `reselectionDepth` it was handed.
final class OutcomeByNameAuthoring: SelectedFeatureAuthoring, Sendable {
    private struct State {
        var calls: [(name: String, depth: Int)] = []
    }
    private let state = Mutex(State())
    private let refuse: Set<String>

    init(refuse: Set<String>) {
        self.refuse = refuse
    }

    var calls: [(name: String, depth: Int)] { state.withLock { $0.calls } }

    func author(
        _ selection: SelectedFeature, reselectionDepth: Int, context: ActContext
    ) async throws -> FeatureAuthoringOutcome {
        state.withLock { $0.calls.append((selection.name.rawValue, reselectionDepth)) }
        return refuse.contains(selection.name.rawValue) ? .refused : .authored
    }

    func resumeUnfinished(_ context: ActContext) async throws -> FeatureAuthoringOutcome? { nil }
}

private func reselectionFeature(_ raw: String, repositories: [String] = ["backend"]) throws -> SelectedFeature {
    SelectedFeature(
        name: try #require(FeatureName(rawValue: raw)), reasoning: "walk test",
        sequence: nil, repositories: repositories, adoptedCardIssueIDs: []
    )
}

@Suite("Re-selection walk (P11.6)")
struct ReselectionWalkTests {
    @Test("reselectionsMax = 1: refuse A, re-select, refuse B: walk ends at depth 1, naming A to the second request")
    func walkEndsAtBoundAfterTwoRefusals() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let selector = SequencedFeatureSelector(
            outcomes: [.selected(try reselectionFeature("FEAT-A")), .selected(try reselectionFeature("FEAT-B"))]
        )
        let transaction = OutcomeByNameAuthoring(refuse: ["FEAT-A", "FEAT-B"])
        let selection = FeatureSelection(selector: selector, transaction: transaction, reselectionsMax: 1)
        let (context, _) = try makeSelectionContext(journal, repositories: selectionRepositories())

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .refused)
        #expect(selector.callCount == 2)
        #expect(transaction.calls.map(\.name) == ["FEAT-A", "FEAT-B"])
        #expect(transaction.calls.map(\.depth) == [0, 1])
        #expect(selector.requests.first?.refusedThisNight == [])
        #expect(selector.requests[1].refusedThisNight == [try #require(FeatureName(rawValue: "FEAT-A"))])

        let events = try journal.events().map(\.event)
        guard case .featureReselected(let depth, let afterRefusalOf, let reselectionsMax) = try #require(
            events.first { if case .featureReselected = $0 { true } else { false } }
        ) else {
            Issue.record("expected featureReselected")
            return
        }
        #expect(depth == 1)
        #expect(afterRefusalOf == "FEAT-A")
        #expect(reselectionsMax == 1)

        guard case .reselectionBoundReached(let boundDepth, let boundMax) = try #require(
            events.first { if case .reselectionBoundReached = $0 { true } else { false } }
        ) else {
            Issue.record("expected reselectionBoundReached")
            return
        }
        #expect(boundDepth == 1)
        #expect(boundMax == 1)
    }

    @Test("reselectionsMax = 1: refuse A, re-select, B authored cleanly: .authored")
    func walkSucceedsOnReselection() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let selector = SequencedFeatureSelector(
            outcomes: [.selected(try reselectionFeature("FEAT-A")), .selected(try reselectionFeature("FEAT-B"))]
        )
        let transaction = OutcomeByNameAuthoring(refuse: ["FEAT-A"])
        let selection = FeatureSelection(selector: selector, transaction: transaction, reselectionsMax: 1)
        let (context, _) = try makeSelectionContext(journal, repositories: selectionRepositories())

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .authored)
        #expect(selector.callCount == 2)
        #expect(transaction.calls.map(\.name) == ["FEAT-A", "FEAT-B"])
        #expect(transaction.calls.map(\.depth) == [0, 1])
    }

    @Test("reselectionsMax = 0: the first Refusal ends the walk at depth 0, with no re-selection")
    func zeroReselectionsMaxEndsWalkImmediately() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let selector = SequencedFeatureSelector(outcomes: [.selected(try reselectionFeature("FEAT-A"))])
        let transaction = OutcomeByNameAuthoring(refuse: ["FEAT-A"])
        let selection = FeatureSelection(selector: selector, transaction: transaction, reselectionsMax: 0)
        let (context, _) = try makeSelectionContext(journal, repositories: selectionRepositories())

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .refused)
        #expect(selector.callCount == 1)
        #expect(transaction.calls.map(\.depth) == [0])
        let events = try journal.events().map(\.type)
        #expect(events.contains(.reselectionBoundReached))
        #expect(!events.contains(.featureReselected))
    }

    @Test("A forced named Feature that is refused never re-selects")
    func forcedNamedFeatureNeverReselects() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let named = try #require(FeatureName(rawValue: "FEAT-A"))
        let selector = SequencedFeatureSelector(
            outcomes: [
                .selected(try reselectionFeature("FEAT-A")), .selected(try reselectionFeature("FEAT-B"))
            ]
        )
        let transaction = OutcomeByNameAuthoring(refuse: ["FEAT-A"])
        let selection = FeatureSelection(selector: selector, transaction: transaction, reselectionsMax: 2)
        let (context, _) = try makeSelectionContext(
            journal, repositories: selectionRepositories(), trigger: .forcedForFeature(named)
        )

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .refused)
        #expect(selector.callCount == 1)
        let events = try journal.events().map(\.type)
        #expect(!events.contains(.featureReselected))
        #expect(!events.contains(.reselectionBoundReached))
    }

    @Test("The selector re-returning an already-refused Feature throws reselectedFeatureAlreadyRefused")
    func repeatedRefusedFeatureThrows() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let selector = SequencedFeatureSelector(
            outcomes: [
                .selected(try reselectionFeature("FEAT-A")), .selected(try reselectionFeature("FEAT-A"))
            ]
        )
        let transaction = OutcomeByNameAuthoring(refuse: ["FEAT-A"])
        let selection = FeatureSelection(selector: selector, transaction: transaction, reselectionsMax: 2)
        let (context, _) = try makeSelectionContext(journal, repositories: selectionRepositories())

        await #expect(throws: FeatureSelectionError.self) {
            try await selection.selectAndAuthor(context)
        }
        #expect(selector.callCount == 2)
    }

    @Test("A halt ends the walk without re-selecting")
    func haltDoesNotReselect() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let feature = try #require(FeatureName(rawValue: "FEAT-A"))
        let selector = SequencedFeatureSelector(
            outcomes: [
                .halted(feature: feature, cause: .repositoriesUndetermined),
                .selected(try reselectionFeature("FEAT-B"))
            ]
        )
        let transaction = OutcomeByNameAuthoring(refuse: [])
        let selection = FeatureSelection(selector: selector, transaction: transaction, reselectionsMax: 2)
        let boards = try await makeBuildActBoards()
        let (context, _) = try makeSelectionContext(journal, repositories: selectionRepositories(), boards: boards)

        let outcome = try await selection.selectAndAuthor(context)

        #expect(outcome == .halted)
        #expect(selector.callCount == 1)
        #expect(transaction.calls.isEmpty)
    }
}
