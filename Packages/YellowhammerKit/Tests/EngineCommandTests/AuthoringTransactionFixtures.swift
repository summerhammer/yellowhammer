import Domain
@testable import Engine
import Foundation
@testable import Journal
import Synchronization
import Testing

// roadmap P9.4: fixtures shared by AuthoringTransactionTests.swift and its adoption/failure companions.
// The breakdown here is scripted — the model-authored content is never asserted, only the wiring.

/// A `FeatureBreakdownDrafting` that hands back a scripted breakdown per call (the last one repeats)
/// and counts its calls.
final class ScriptedBreakdown: FeatureBreakdownDrafting, Sendable {
    private let state = Mutex(0)
    private let breakdowns: [FeatureBreakdown]

    init(_ breakdowns: FeatureBreakdown...) {
        self.breakdowns = breakdowns
    }

    var callCount: Int { state.withLock { $0 } }

    func breakdown(for selection: SelectedFeature, mainlines: ResolvedMainlines) async throws -> FeatureBreakdown {
        let index = state.withLock { count -> Int in
            defer { count += 1 }
            return count
        }
        return breakdowns[min(index, breakdowns.count - 1)]
    }
}

func authoringKind(_ text: String = "impl.boilerplate") throws -> Kind {
    try #require(Kind(text))
}

/// Two backend Cards and one mobile Card, in authored order.
func authoringBreakdown(
    backendTitles: [String] = ["Backend one", "Backend two"], mobileTitles: [String] = ["Mobile one"]
) throws -> FeatureBreakdown {
    let kind = try authoringKind()
    return FeatureBreakdown(
        definitionOfDone: "The Feature is done.",
        cards: backendTitles.map { CardDraft(repository: "backend", kind: kind, title: $0, unitOfWork: "Do \($0)") }
            + mobileTitles.map { CardDraft(repository: "mobile", kind: kind, title: $0, unitOfWork: "Do \($0)") }
    )
}

func authoringSelection(
    adopting adopted: [String] = [], sequence: FeatureSequence? = nil
) throws -> SelectedFeature {
    SelectedFeature(
        name: try #require(FeatureName(rawValue: "FEAT-1")), reasoning: "Because.", sequence: sequence,
        repositories: ["backend", "mobile"], adoptedCardIssueIDs: adopted
    )
}

/// One author Act's worth of wiring: a Journal, a board, and the selector and breakdown seams.
final class AuthoringRig {
    let fixture: OutboxJournalFixture
    let journal: JournalStore
    let boards: NightCardTestBoards
    let selector: ScriptedFeatureSelector
    let drafting: ScriptedBreakdown
    let selection: FeatureSelection

    init(
        adopting adopted: [String] = [], sequence: FeatureSequence? = nil, drafting: ScriptedBreakdown? = nil
    ) async throws {
        fixture = try OutboxJournalFixture()
        journal = try fixture.open()
        boards = try await makeBuildActBoards()
        selector = ScriptedFeatureSelector(
            outcome: .selected(try authoringSelection(adopting: adopted, sequence: sequence))
        )
        self.drafting = try drafting ?? ScriptedBreakdown(try authoringBreakdown())
        selection = FeatureSelection(selector: selector, transaction: AuthoringTransaction(drafting: self.drafting))
    }

    /// A fresh author Act's context (a new run under the Act Lease). The previous run's Lease is released
    /// first, the way a finished or killed run leaves it.
    func context(previous: ActContext? = nil) throws -> ActContext {
        if let previous {
            try journal.releaseActLease(runID: previous.runID)
        }
        return try makeSelectionContext(journal, repositories: selectionRepositories(), boards: boards).context
    }

    func run(_ context: ActContext) async throws -> FeatureAuthoringOutcome {
        try await selection.selectAndAuthor(context)
    }
}

/// The same context with an Outbox that throws after the board applied `interruptAt`'s entry — a crash
/// between the board's answer and the Journal hearing of it.
func crashing(_ base: ActContext, boards: NightCardTestBoards, afterApplying count: Int) -> ActContext {
    let applied = Mutex(0)
    let outbox = Outbox(
        journal: base.journal, board: boards.writing, runID: base.runID, act: .author, nightID: base.night.id
    ) { _ in
        let seen = applied.withLock { value -> Int in
            value += 1
            return value
        }
        if seen == count { throw SimulatedCrash() }
    }
    return ActContext(
        act: base.act, mode: base.mode, trigger: base.trigger, runID: base.runID, journal: base.journal,
        night: base.night, outbox: outbox, board: base.board, mainlines: base.mainlines,
        workspace: base.workspace, repositories: base.repositories
    )
}

func cardRows(_ journal: JournalStore) throws -> [CardRecord] {
    try journal.cards().sorted { ($0.repository, $0.authoredOrder) < ($1.repository, $1.authoredOrder) }
}
