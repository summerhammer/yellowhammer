import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Repositories
import Testing

// roadmap P8.3: refusing a Card before dispatch when its declared scope falls under a repository's
// configured protected path (bounds/refuse-protected-paths-before-dispatch). Fixture helpers are shared
// with ReadinessCheckTests.swift.

private let protectedBackendRepo = Repo(
    name: "backend", path: "/nonexistent/backend", role: .backend, protectedPaths: ["Secrets/"]
)
private let protectedRepositories = ProjectRepositories(workingRepos: [protectedBackendRepo])

/// Card one has a resolvable brief and clause (as `staleBlockDiverges` does), so readiness would
/// otherwise pass — isolating the refusal as the only reason it does not dispatch.
private func makeReadyCardOne(_ scenario: ReadinessScenario) throws {
    try scenario.journal.recordArchitecturalBrief(cardID: scenario.cardOne, prose: "A brief.")
    try scenario.journal.insertClause(JournalStore.NewClause(
        cid: "c1", issueID: scenario.issueOne, level: "card", text: "A clause",
        locationID: "resolvable/story", provenance: "Author-supplied", citationProvenance: "Author-supplied"
    ))
}

private func makeReadinessCheck() -> ReadinessCheck {
    ReadinessCheck(
        provenance: FakeProvenanceTester(), citations: FakeCitationResolver(resolvable: ["resolvable/story"])
    )
}

@Test("A Card scoped onto a protected path is refused before dispatch")
func protectedPathRefusesBeforeDispatch() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try makeReadyCardOne(scenario)
    try scenario.journal.recordDeclaredScope(cardID: scenario.cardOne, paths: ["Sources/App/", "Secrets/keys.env"])

    try await runReadinessAct(scenario, readiness: makeReadinessCheck(), repositories: protectedRepositories)

    #expect(scenario.recorder.seen.map(\.issueID) == [scenario.issueTwo])

    let card = try #require(try scenario.journal.card(issueID: scenario.issueOne))
    #expect(card.state == .waitingOnYou)
    #expect(card.waitingReason == .overreach)

    let refused = try scenario.journal.events(ofType: .protectedPathRefused)
    #expect(refused.count == 1)
    guard case .protectedPathRefused(_, let issueID, let repository, let declaredPath, let protectedPath) =
        refused[0].event
    else {
        Issue.record("expected protectedPathRefused")
        return
    }
    #expect(issueID == scenario.issueOne)
    #expect(repository == "backend")
    #expect(declaredPath == "Secrets/keys.env")
    #expect(protectedPath == "Secrets/")

    let attempts = try scenario.journal.attemptHistory(cardID: scenario.cardOne)
    #expect(attempts.attempts.isEmpty)

    #expect(try scenario.journal.events(ofType: .readinessCheckFailed).isEmpty)

    let laneEnded = try scenario.journal.events(ofType: .repoLaneEnded)
    guard case .repoLaneEnded(_, let cardsRun, _, let cardsSkipped) = laneEnded[0].event else {
        Issue.record("expected repoLaneEnded")
        return
    }
    #expect(cardsRun == 1)
    #expect(cardsSkipped == 1)

    let cardTwo = try #require(try scenario.journal.card(issueID: scenario.issueTwo))
    #expect(cardTwo.state == .todo)
}

@Test("The refusal notice carries the protected path and the limitation")
func refusalNoticeCarriesLimitation() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try makeReadyCardOne(scenario)
    try scenario.journal.recordDeclaredScope(cardID: scenario.cardOne, paths: ["Sources/App/", "Secrets/keys.env"])

    try await runReadinessAct(scenario, readiness: makeReadinessCheck(), repositories: protectedRepositories)

    let comments = await scenario.boards.writing.comments.filter { $0.issue.rawValue == scenario.issueOne }
    let comment = try #require(comments.last)
    #expect(comment.body.contains("Secrets/"))
    #expect(comment.body.contains(ProtectedPaths.limitation))
}

@Test("A Card whose scope avoids the protected paths is dispatched")
func scopeAvoidingProtectedPathsDispatches() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try makeReadyCardOne(scenario)
    try scenario.journal.recordDeclaredScope(cardID: scenario.cardOne, paths: ["Sources/App/"])

    try await runReadinessAct(scenario, readiness: makeReadinessCheck(), repositories: protectedRepositories)

    #expect(scenario.recorder.seen.map(\.issueID) == [scenario.issueOne, scenario.issueTwo])
    #expect(try scenario.journal.events(ofType: .protectedPathRefused).isEmpty)
}

@Test("A Card with no declared scope is not refused")
func noDeclaredScopeIsNotRefused() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try makeReadyCardOne(scenario)

    try await runReadinessAct(scenario, readiness: makeReadinessCheck(), repositories: protectedRepositories)

    #expect(scenario.recorder.seen.map(\.issueID) == [scenario.issueOne, scenario.issueTwo])
    #expect(try scenario.journal.events(ofType: .protectedPathRefused).isEmpty)
}

@Test("A scope edited on the board is reconciled before the check")
func scopeEditedOnBoardIsReconciled() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try makeReadyCardOne(scenario)

    let clause = DoDClause(
        cid: "c1", text: "A clause", citation: "resolvable/story", citationProvenance: "Author-supplied"
    )
    let block = CardManagedBlock(
        kind: "card", repository: "backend", scope: ["Secrets/keys.env"], state: .todo, lanePosition: 1,
        laneLength: 2, brief: ArchitecturalBrief(prose: "A brief.", transcriptions: []),
        definitionOfDone: [clause], attempts: []
    )
    await scenario.boards.writing.seed(issue: scenario.issueOne, description: fenced(block: block.render()))

    try await runReadinessAct(
        scenario, readiness: makeReadinessCheck(),
        updatedObjects: [object(scenario.issueOne, state: stateTodo, description: fenced(block: block.render()))],
        repositories: protectedRepositories
    )

    #expect(try scenario.journal.declaredScope(cardID: scenario.cardOne) == ["Secrets/keys.env"])

    let card = try #require(try scenario.journal.card(issueID: scenario.issueOne))
    #expect(card.state == .waitingOnYou)
    #expect(card.waitingReason == .overreach)

    let refused = try scenario.journal.events(ofType: .protectedPathRefused)
    #expect(refused.count == 1)
}

@Test("Divergence wins over all protected overlaps, which are recorded and rechecked next dispatch")
func divergenceWinsOverOverreach() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try makeReadyCardOne(scenario)
    try scenario.journal.recordDeclaredScope(cardID: scenario.cardOne, paths: ["Secrets/", "Secrets/other"])
    try scenario.journal.recordTranscriptionBlocks(cardID: scenario.cardOne, [
        TranscriptionBlock(
            repository: "backend", paths: ["a.swift"], mainlineCommit: "deadbeef", content: "old content",
            contentHash: ManagedBlockFence.sha256("old content"), authorSupplied: false
        )
    ])
    let repositories = ProjectRepositories(workingRepos: [Repo(
        name: "backend", path: "/nonexistent/backend", role: .backend, protectedPaths: ["Secrets/", "Secrets/nested"]
    )])
    let stale = ReadinessCheck(
        provenance: FakeProvenanceTester(verdicts: ["backend": .stale(changedPaths: ["a.swift"])]),
        citations: FakeCitationResolver()
    )
    let verdict = try await directEvaluate(
        scenario, cardID: scenario.cardOne, readiness: stale, repositories: repositories
    )
    guard case .diverged = verdict else { Issue.record("expected Divergence"); return }
    #expect(try scenario.journal.card(id: scenario.cardOne).waitingReason == .divergence)
    #expect(try scenario.journal.events(ofType: .protectedPathRefused).count == 3)
    #expect(try scenario.journal.consecutiveDivergences(cardID: scenario.cardOne) == 1)

    let next = try await directEvaluate(
        scenario, cardID: scenario.cardOne, readiness: makeReadinessCheck(), repositories: repositories
    )
    guard case .refused = next else { Issue.record("expected overreach on next clean dispatch"); return }
    #expect(try scenario.journal.card(id: scenario.cardOne).waitingReason == .overreach)
    #expect(try scenario.journal.events(ofType: .protectedPathRefused).count == 6)
    #expect(try scenario.journal.consecutiveDivergences(cardID: scenario.cardOne) == 1)
    #expect(try scenario.journal.attemptHistory(cardID: scenario.cardOne).attempts.isEmpty)
}

@Test("Overreach retains precedence over missing structure, bad citations and untestable provenance",
      arguments: [false, true])
func overreachKeepsOtherReadinessPriorities(withUntestableBlock: Bool) async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try scenario.journal.recordDeclaredScope(cardID: scenario.cardOne, paths: ["Secrets/key"])
    if withUntestableBlock {
        try scenario.journal.recordTranscriptionBlocks(cardID: scenario.cardOne, [
            TranscriptionBlock(repository: "backend", paths: ["a.swift"], mainlineCommit: "deadbeef",
                               content: "old", contentHash: "hash", authorSupplied: false)
        ])
        try scenario.journal.insertClause(JournalStore.NewClause(
            cid: "bad", issueID: scenario.issueOne, level: "card", text: "bad citation",
            locationID: "missing/story", provenance: "Author-supplied", citationProvenance: "Author-supplied"
        ))
    }
    let readiness = ReadinessCheck(
        provenance: FakeProvenanceTester(verdicts: ["backend": .untestable(reason: "missing repository")]),
        citations: FakeCitationResolver()
    )
    let verdict = try await directEvaluate(
        scenario, cardID: scenario.cardOne, readiness: readiness, repositories: protectedRepositories
    )
    guard case .refused = verdict else { Issue.record("expected overreach"); return }
    #expect(try scenario.journal.events(ofType: .readinessCheckFailed).isEmpty)
    #expect(try scenario.journal.card(id: scenario.cardOne).waitingReason == .overreach)
}
