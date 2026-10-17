import Domain
@testable import Engine
import Foundation
import Journal
import Repositories
import Testing

// OQ165 (graph-execution/run-a-card#spec-commit): the Readiness Check yields the specification commit its
// citations resolved against, and the worker instruction composed from it names that commit without naming
// any path to the specification. Fixture helpers live in ReadinessCheckTests.swift.

@Test("A Ready verdict carries the commit the first resolving citation resolved against")
func readyVerdictCarriesResolverCommit() async throws {
    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    let readiness = ReadinessCheck(provenance: FakeProvenanceTester(), citations: FakeCitationResolver())

    let verdict = try await directEvaluate(scenario, cardID: scenario.cardTwo, readiness: readiness)

    guard case .ready(let ready) = verdict else {
        Issue.record("expected the second Card to be Ready, got \(verdict)")
        return
    }
    #expect(ready.specCommit == "deadbeef")
}

@Test("The commit is the fixture specification source's mainline head, and the worker instruction omits its path")
func specCommitIsFixtureHeadAndInstructionOmitsPath() async throws {
    let spec = EngineGitFixture(name: "readiness-spec-\(UUID().uuidString)")
    await spec.initRepo()
    try await spec.commit(filename: "auth/login.md", content: "first")
    let head = try await spec.commit(filename: "auth/login.md", content: "second")

    let scenario = try await makeReadinessScenario()
    defer { cleanup(scenario) }
    try scenario.journal.recordArchitecturalBrief(cardID: scenario.cardOne, prose: "A brief.")
    try scenario.journal.insertClause(JournalStore.NewClause(
        cid: "c1", issueID: scenario.issueOne, level: "card", text: "A clause",
        locationID: "auth/login", provenance: "Author-supplied", citationProvenance: "Author-supplied"
    ))
    let repositories = ProjectRepositories(
        workingRepos: readinessRepositories.workingRepos, specSource: SpecSource(path: spec.path)
    )
    let readiness = ReadinessCheck(provenance: FakeProvenanceTester(), citations: MainlineReader())

    let verdict = try await directEvaluate(
        scenario, cardID: scenario.cardOne, readiness: readiness, repositories: repositories
    )

    guard case .ready(let ready) = verdict else {
        Issue.record("expected the Card to be Ready, got \(verdict)")
        return
    }
    #expect(ready.specCommit == head)

    let instruction = Instruction(
        pass: .worker,
        card: InstructionCard(key: "YLH-1", title: "A card"),
        brief: ready.brief,
        definitionOfDone: [Domain.DoDClause(id: "c1", text: "A clause", citation: SpecCitation("auth/login"))],
        repository: InstructionRepository(
            repo: readinessRepositories.workingRepos[0], worktreePath: "/worktrees/backend/YLH-1",
            featureBranch: "feature/ylh-1", check: .none
        ),
        route: Route(cli: "claude", model: "sonnet", effort: "medium")!,
        payloads: .none,
        specCommit: ready.specCommit
    )
    let text = instruction.render()
    #expect(text.contains("Specification commit: \(head)"))
    #expect(!text.contains(spec.path))
}
