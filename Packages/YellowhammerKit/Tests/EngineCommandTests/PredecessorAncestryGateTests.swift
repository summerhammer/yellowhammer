import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

// roadmap P9.2: the predecessor-ancestry gate. Reads the most recent Feature that is not in flight
// (its Cycle archived), evaluates ancestry for its Feature Branch in the repositories its Cycle
// touched, re-tests merge only for the unmerged ones, and records what it found. Allocates no
// Worktree, dispatches nothing, records no Attempt. Fixtures and helpers are in
// PredecessorAncestryGateFixtures.swift.

@Suite("Predecessor-ancestry gate")
struct PredecessorAncestryGateTests {
    @Test("No predecessor Feature: landed, no events")
    func noPredecessorIsLanded() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let (context, _) = try makeGateContext(journal, repositories: nil)
        let gate = PredecessorAncestryGate()

        let outcome = try await gate.check(context)

        #expect(outcome == .landed)
        let events = try journal.events().map(\.type)
        #expect(!events.contains(.predecessorAncestryObserved))
        #expect(!events.contains(.mainlineConflictDetected))
    }

    @Test("Predecessor merged in every repository: landed, k = N observed, closure fires once")
    func predecessorMergedInAllRepositoriesIsLanded() async throws {
        let backend = GateGitFixture(name: "gate-merged-backend")
        await backend.initRepo()
        _ = try await backend.commit(message: "init")
        _ = await backend.run(["checkout", "-b", "yh-proj-predecessor"])
        _ = try await backend.commit(filename: "feat.txt", content: "feat", message: "feature commit")
        _ = await backend.run(["checkout", "main"])
        _ = await backend.run(["merge", "--no-ff", "-m", "merge", "yh-proj-predecessor"])

        let mobile = GateGitFixture(name: "gate-merged-mobile")
        await mobile.initRepo()
        _ = try await mobile.commit(message: "init")
        _ = await mobile.run(["checkout", "-b", "yh-proj-predecessor"])
        _ = try await mobile.commit(filename: "feat.txt", content: "feat", message: "feature commit")
        _ = await mobile.run(["checkout", "main"])
        _ = await mobile.run(["merge", "--no-ff", "-m", "merge", "yh-proj-predecessor"])

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-0", branch: "yh-proj-predecessor", repositories: ["backend", "mobile"]
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        try insertGateCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend")
        try insertGateCard(journal, cycleID: cycleID, issueID: "MOB-1", repository: "mobile")

        let repositories = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: backend.path, role: .backend),
            Repo(name: "mobile", path: mobile.path, role: .mobile)
        ])
        let closure = ScriptedPostMergeClosure()
        let gate = PredecessorAncestryGate(closure: closure)

        let (context1, _) = try makeGateContext(journal, repositories: repositories)
        let outcome1 = try await gate.check(context1)
        #expect(outcome1 == .landed)
        #expect(closure.callCount == 1)

        let events = try journal.events()
        let observed = try #require(events.first { $0.type == .predecessorAncestryObserved })
        guard case .predecessorAncestryObserved(let issueID, let merged, let unmerged) = observed.event else {
            Issue.record("expected predecessorAncestryObserved")
            return
        }
        #expect(issueID == "FEAT-0")
        #expect(merged == ["backend", "mobile"])
        #expect(unmerged.isEmpty)

        // A second pass must not fire the closure again.
        try journal.releaseActLease(runID: context1.runID)
        let (context2, _) = try makeGateContext(journal, repositories: repositories)
        let outcome2 = try await gate.check(context2)
        #expect(outcome2 == .landed)
        #expect(closure.callCount == 1)
    }

    @Test("Predecessor merged in none of N repositories: notLanded naming every repository")
    func predecessorMergedInNoneIsNotLanded() async throws {
        let backend = GateGitFixture(name: "gate-none-backend")
        await backend.initRepo()
        _ = try await backend.commit(message: "init")
        _ = await backend.run(["checkout", "-b", "yh-proj-none"])
        _ = try await backend.commit(filename: "feat.txt", content: "feat", message: "feature commit")
        _ = await backend.run(["checkout", "main"])

        let mobile = GateGitFixture(name: "gate-none-mobile")
        await mobile.initRepo()
        _ = try await mobile.commit(message: "init")
        _ = await mobile.run(["checkout", "-b", "yh-proj-none"])
        _ = try await mobile.commit(filename: "feat.txt", content: "feat", message: "feature commit")
        _ = await mobile.run(["checkout", "main"])

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-1", branch: "yh-proj-none", repositories: ["backend", "mobile"]
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        try insertGateCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend")
        try insertGateCard(journal, cycleID: cycleID, issueID: "MOB-1", repository: "mobile")

        let repositories = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: backend.path, role: .backend),
            Repo(name: "mobile", path: mobile.path, role: .mobile)
        ])
        let closure = ScriptedPostMergeClosure()
        let gate = PredecessorAncestryGate(closure: closure)
        let (context, _) = try makeGateContext(journal, repositories: repositories)

        let outcome = try await gate.check(context)

        guard case .notLanded(let issueID, let repos) = outcome else {
            Issue.record("expected notLanded")
            return
        }
        #expect(issueID == "FEAT-1")
        #expect(repos == ["backend", "mobile"])
        #expect(closure.callCount == 0)
    }

    @Test("Partial Landing: merged in one of two repositories names only the unmerged one")
    func predecessorPartiallyMergedNamesUnmergedOnly() async throws {
        let backend = GateGitFixture(name: "gate-partial-backend")
        await backend.initRepo()
        _ = try await backend.commit(message: "init")
        _ = await backend.run(["checkout", "-b", "yh-proj-partial"])
        _ = try await backend.commit(filename: "feat.txt", content: "feat", message: "feature commit")
        _ = await backend.run(["checkout", "main"])
        _ = await backend.run(["merge", "--no-ff", "-m", "merge", "yh-proj-partial"])

        let mobile = GateGitFixture(name: "gate-partial-mobile")
        await mobile.initRepo()
        _ = try await mobile.commit(message: "init")
        _ = await mobile.run(["checkout", "-b", "yh-proj-partial"])
        _ = try await mobile.commit(filename: "feat.txt", content: "feat", message: "feature commit")
        _ = await mobile.run(["checkout", "main"])
        // Not merged.

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-2", branch: "yh-proj-partial", repositories: ["backend", "mobile"]
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        try insertGateCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend")
        try insertGateCard(journal, cycleID: cycleID, issueID: "MOB-1", repository: "mobile")

        let repositories = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: backend.path, role: .backend),
            Repo(name: "mobile", path: mobile.path, role: .mobile)
        ])
        let gate = PredecessorAncestryGate()
        let (context, _) = try makeGateContext(journal, repositories: repositories)

        let outcome = try await gate.check(context)

        guard case .notLanded(_, let repos) = outcome else {
            Issue.record("expected notLanded")
            return
        }
        #expect(repos == ["mobile"])

        // The merged repository gets no merge test / no conflict event.
        let events = try journal.events()
        #expect(!events.contains { $0.type == .mainlineConflictDetected })
    }

    @Test("An unmerged branch that conflicts with a moved mainline reports a Mainline Conflict")
    func conflictingUnmergedBranchReportsMainlineConflict() async throws {
        let backend = GateGitFixture(name: "gate-conflict-backend")
        await backend.initRepo()
        _ = try await backend.commit(filename: "shared.txt", content: "base", message: "init")
        _ = await backend.run(["checkout", "-b", "yh-proj-conflict"])
        _ = try await backend.commit(filename: "shared.txt", content: "branch change", message: "branch edit")
        _ = await backend.run(["checkout", "main"])
        _ = try await backend.commit(filename: "shared.txt", content: "mainline change", message: "mainline edit")

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-3", branch: "yh-proj-conflict", repositories: ["backend"]
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        try insertGateCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend")

        let repositories = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: backend.path, role: .backend)
        ])
        let gate = PredecessorAncestryGate()
        let (context, _) = try makeGateContext(journal, repositories: repositories)

        let outcome = try await gate.check(context)

        guard case .notLanded(_, let repos) = outcome else {
            Issue.record("expected notLanded")
            return
        }
        #expect(repos == ["backend"])

        let events = try journal.events()
        let conflict = try #require(events.first { $0.type == .mainlineConflictDetected })
        guard case .mainlineConflictDetected(let issueID, let repository, let paths) = conflict.event else {
            Issue.record("expected mainlineConflictDetected")
            return
        }
        #expect(issueID == "FEAT-3")
        #expect(repository == "backend")
        #expect(paths == ["shared.txt"])

        // No Card state changed and no Block Reason was minted: a Mainline Conflict is reported only.
        let card = try journal.card(issueID: "BACK-1")
        #expect(card?.state == .todo)
        #expect(card?.blockReason == nil)
    }

    @Test("A predecessor touching a repository not in the Project's configuration throws")
    func predecessorTouchingUnconfiguredRepositoryThrows() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-4", branch: "yh-proj-ghost", repositories: ["ghost"]
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        try insertGateCard(journal, cycleID: cycleID, issueID: "GHOST-1", repository: "ghost")

        let repositories = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: "/tmp/does-not-matter", role: .backend)
        ])
        let gate = PredecessorAncestryGate()
        let (context, _) = try makeGateContext(journal, repositories: repositories)

        await #expect(throws: PredecessorAncestryGateError.self) {
            _ = try await gate.check(context)
        }
    }

    @Test("A predecessor without a recorded branch throws")
    func predecessorWithoutBranchThrows() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-5", branch: nil, repositories: ["backend"]
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        try insertGateCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend")

        let repositories = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: "/tmp/does-not-matter", role: .backend)
        ])
        let gate = PredecessorAncestryGate()
        let (context, _) = try makeGateContext(journal, repositories: repositories)

        await #expect(throws: PredecessorAncestryGateError.self) {
            _ = try await gate.check(context)
        }
    }
}
