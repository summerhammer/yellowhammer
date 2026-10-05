import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

// The predecessor-ancestry gate tests each repository's own recorded Feature Branch, which Orca ADE may
// have reported with a different `<prefix>/` per repository. Split out of PredecessorAncestryGateTests.swift
// to keep it short.

@Suite("Predecessor-ancestry gate recorded Feature Branch")
struct PredecessorAncestryGatePrefixTests {
    @Test("Two repositories with different prefixes: each repository's own recorded branch is tested")
    func eachRepositoryTestsItsOwnRecordedBranch() async throws {
        let backend = GateGitFixture(name: "gate-prefix-backend")
        await backend.initRepo()
        _ = try await backend.commit(message: "init")
        _ = await backend.run(["checkout", "-b", "rozd/yh-proj-pre"])
        _ = try await backend.commit(filename: "feat.txt", content: "feat", message: "feature commit")
        _ = await backend.run(["checkout", "main"])
        _ = await backend.run(["merge", "--no-ff", "-m", "merge", "rozd/yh-proj-pre"])

        let mobile = GateGitFixture(name: "gate-prefix-mobile")
        await mobile.initRepo()
        _ = try await mobile.commit(message: "init")
        _ = await mobile.run(["checkout", "-b", "alice/yh-proj-pre"])
        _ = try await mobile.commit(filename: "feat.txt", content: "feat", message: "feature commit")
        _ = await mobile.run(["checkout", "main"])
        // Not merged.

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-P", branch: "yh-proj-pre", repositories: ["backend", "mobile"]
        )
        try journal.recordFeatureBranch(
            featureID: featureID, repository: "backend", branch: FeatureBranch(name: "rozd/yh-proj-pre")
        )
        try journal.recordFeatureBranch(
            featureID: featureID, repository: "mobile", branch: FeatureBranch(name: "alice/yh-proj-pre")
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        try insertGateCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend")
        try insertGateCard(journal, cycleID: cycleID, issueID: "MOB-1", repository: "mobile")

        let repositories = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: backend.path, role: .backend),
            Repo(name: "mobile", path: mobile.path, role: .mobile)
        ])
        let (context, _) = try makeGateContext(journal, repositories: repositories)

        let outcome = try await PredecessorAncestryGate().check(context)

        guard case .notLanded(let issueID, let repos) = outcome else {
            Issue.record("expected notLanded, got \(outcome)")
            return
        }
        #expect(issueID == "FEAT-P")
        #expect(repos == ["mobile"])
        let landings = try journal.landings(featureID: featureID)
        #expect(landings["backend"] != nil)
        #expect(landings["mobile"] == nil)
    }
}
