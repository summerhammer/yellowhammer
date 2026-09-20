import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

// roadmap P9.9: the predecessor gate's own durable state — touched repositories recorded at
// selection (never derived from Cards), landings observed pass to pass (first-observation-wins), the
// in-flight Feature observed alongside gating the predecessor, released Features the walk steps past,
// and the indeterminate outcome for a branch that cannot be found with no recorded landing. Split out
// of PredecessorAncestryGateTests.swift to keep that file under the file length limit; shares its
// fixtures (PredecessorAncestryGateFixtures.swift).

@Suite("Predecessor gate: touched repositories, landings, in-flight, released walk (P9.9)")
struct PredecessorGateP99Tests {
    // A landing is recorded and the closure fires for an in-flight, landed Feature; the in-flight
    // skip is still recorded, and nothing is authored.
    @Test("An in-flight, landed Feature is observed alongside the in-flight skip")
    func inFlightLandedFeatureIsObservedAlongsideTheSkip() async throws {
        let backend = GateGitFixture(name: "p99-inflight-landed")
        await backend.initRepo()
        _ = try await backend.commit(message: "init")
        _ = await backend.run(["checkout", "-b", "yh-proj-inflight"])
        _ = try await backend.commit(filename: "feat.txt", content: "feat", message: "feature commit")
        _ = await backend.run(["checkout", "main"])
        _ = await backend.run(["merge", "--no-ff", "-m", "merge", "yh-proj-inflight"])

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-INFLIGHT", branch: "yh-proj-inflight", repositories: ["backend"],
            inFlight: true, landed: true
        )

        let repositories = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: backend.path, role: .backend)
        ])
        let closure = ScriptedPostMergeClosure()
        let authoring = ScriptedFeatureAuthoring(outcome: .authored)

        let invocation = EngineInvocation(
            act: .author, mode: .rehearsal, nightStart: gateNightStart, journal: journal,
            trigger: .forced, runID: RunID(), repositories: repositories,
            work: AuthorAct(
                predecessorGate: PredecessorAncestryGate(closure: closure), authoring: authoring
            ).work
        )
        try await invocation.run()

        #expect(!authoring.wasCalled)
        #expect(closure.callCount == 1)

        let events = try journal.events()
        #expect(events.contains { $0.type == .authoringSkippedFeatureInFlight })
        let observed = try #require(events.first { $0.type == .predecessorAncestryObserved })
        guard case .predecessorAncestryObserved(let issueID, let merged, let unmerged) = observed.event else {
            Issue.record("expected predecessorAncestryObserved")
            return
        }
        #expect(issueID == "FEAT-INFLIGHT")
        #expect(merged == ["backend"])
        #expect(unmerged.isEmpty)

        let landings = try journal.landings(featureID: featureID)
        #expect(landings["backend"] != nil)
    }

    // A branch freshly cut from mainline is trivially an ancestor, so an in-flight Feature whose
    // Cycle has NOT landed must record no landing.
    @Test("An in-flight, unlanded Feature records no landing")
    func inFlightUnlandedFeatureRecordsNoLanding() async throws {
        let backend = GateGitFixture(name: "p99-inflight-unlanded")
        await backend.initRepo()
        _ = try await backend.commit(message: "init")
        _ = await backend.run(["checkout", "-b", "yh-proj-fresh"])

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-FRESH", branch: "yh-proj-fresh", repositories: ["backend"],
            inFlight: true, landed: false
        )

        let repositories = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: backend.path, role: .backend)
        ])
        let gate = PredecessorAncestryGate()
        let (context, _) = try makeGateContext(journal, repositories: repositories)

        let outcome = try await gate.check(context)

        #expect(outcome == .landed)
        let events = try journal.events().map(\.type)
        #expect(!events.contains(.predecessorAncestryObserved))
        let landings = try journal.landings(featureID: featureID)
        #expect(landings.isEmpty)
    }

    // An unlanded in-flight Feature must not fall through to the predecessor walk: the in-flight skip
    // owns the Night, and no released Feature is named on a Night that authors nothing.
    @Test("An in-flight, unlanded Feature never walks to the predecessor")
    func inFlightUnlandedFeatureNeverWalksToThePredecessor() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        _ = try insertGateFeature(
            journal, issueID: "FEAT-RELEASED", branch: "yh-proj-released", repositories: ["backend"],
            released: true
        )
        _ = try insertGateFeature(
            journal, issueID: "FEAT-FRESH", branch: "yh-proj-fresh", repositories: ["backend"],
            inFlight: true, landed: false
        )

        let gate = PredecessorAncestryGate()
        let (context, _) = try makeGateContext(journal, repositories: nil)

        #expect(try await gate.check(context) == .landed)
        let events = try journal.events().map(\.type)
        #expect(!events.contains(.predecessorWalkSkippedReleasedFeature))
        #expect(!events.contains(.predecessorAncestryObserved))
    }

    @Test("A released Feature is not recorded skipped on a Night the gate stays shut")
    func releasedFeatureIsNotRecordedSkippedWhenTheGateStaysShut() async throws {
        let backend = GateGitFixture(name: "p99-skip-shut")
        await backend.initRepo()
        _ = try await backend.commit(message: "init")
        _ = await backend.run(["checkout", "-b", "yh-proj-older"])
        _ = try await backend.commit(filename: "older.txt", message: "older work")
        _ = await backend.run(["checkout", "main"])

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        _ = try insertGateFeature(
            journal, issueID: "FEAT-OLDER", branch: "yh-proj-older", repositories: ["backend"]
        )
        _ = try insertGateFeature(
            journal, issueID: "FEAT-NEWER", branch: "yh-proj-newer", repositories: ["backend"], released: true
        )

        let repositories = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: backend.path, role: .backend)
        ])
        let gate = PredecessorAncestryGate()
        let (context, _) = try makeGateContext(journal, repositories: repositories)

        let outcome = try await gate.check(context)
        #expect(outcome == .notLanded(predecessorIssueID: "FEAT-OLDER", repositories: ["backend"]))
        #expect(!(try journal.events().map(\.type).contains(.predecessorWalkSkippedReleasedFeature)))
    }

    // The gate opens against the older landed Feature, and the skip is recorded.
    @Test("A released predecessor is skipped by the walk")
    func releasedPredecessorIsSkippedByTheWalk() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let olderID = try insertGateFeature(
            journal, issueID: "FEAT-OLDER", branch: "yh-proj-older", repositories: []
        )
        let newerID = try insertGateFeature(
            journal, issueID: "FEAT-NEWER", branch: "yh-proj-newer", repositories: ["backend"], released: true
        )
        #expect(olderID < newerID)

        let gate = PredecessorAncestryGate()
        let (context, _) = try makeGateContext(journal, repositories: nil)

        let outcome = try await gate.check(context)

        #expect(outcome == .landed)
        let events = try journal.events()
        let skip = try #require(events.first { $0.type == .predecessorWalkSkippedReleasedFeature })
        guard case .predecessorWalkSkippedReleasedFeature(let issueID) = skip.event else {
            Issue.record("expected predecessorWalkSkippedReleasedFeature")
            return
        }
        #expect(issueID == "FEAT-NEWER")

        let releasedLandings = try journal.landings(featureID: newerID)
        #expect(releasedLandings.isEmpty)
    }

    @Test("When every archived Feature has been released, the gate is open and every one is recorded skipped")
    func everyArchivedFeatureReleasedLeavesTheGateOpen() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        _ = try insertGateFeature(
            journal, issueID: "FEAT-R1", branch: "yh-proj-r1", repositories: ["backend"], released: true
        )
        _ = try insertGateFeature(
            journal, issueID: "FEAT-R2", branch: "yh-proj-r2", repositories: ["backend"], released: true
        )

        let gate = PredecessorAncestryGate()
        let (context, _) = try makeGateContext(journal, repositories: nil)

        let outcome = try await gate.check(context)

        #expect(outcome == .landed)
        let skipCount = try journal.events(ofType: .predecessorWalkSkippedReleasedFeature).count
        #expect(skipCount == 2)
    }
}

/// Landings, indeterminate branches and the remaining P9.9 scenarios — split from
/// ``PredecessorGateP99Tests`` to keep each suite's type body under SwiftLint's limit.
@Suite("Predecessor gate: landings, indeterminate branches, touched repositories (P9.9)")
struct PredecessorGateLandingTests {
    // The gate stays open, reading no git for a repository whose landing was already recorded.
    @Test("A landing recorded and its ref then deleted stays open")
    func landingSurvivesTheRefBeingDeleted() async throws {
        let backend = GateGitFixture(name: "p99-ref-deleted")
        await backend.initRepo()
        _ = try await backend.commit(message: "init")
        _ = await backend.run(["checkout", "-b", "yh-proj-deleted"])
        _ = try await backend.commit(filename: "feat.txt", content: "feat", message: "feature commit")
        _ = await backend.run(["checkout", "main"])
        _ = await backend.run(["merge", "--no-ff", "-m", "merge", "yh-proj-deleted"])

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-DELETED", branch: "yh-proj-deleted", repositories: ["backend"]
        )

        let repositories = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: backend.path, role: .backend)
        ])
        let gate = PredecessorAncestryGate()

        let (context1, _) = try makeGateContext(journal, repositories: repositories)
        let outcome1 = try await gate.check(context1)
        #expect(outcome1 == .landed)
        #expect(try journal.landings(featureID: featureID)["backend"] != nil)

        _ = await backend.run(["branch", "-D", "yh-proj-deleted"])
        try journal.releaseActLease(runID: context1.runID)

        let (context2, _) = try makeGateContext(journal, repositories: repositories)
        let outcome2 = try await gate.check(context2)

        #expect(outcome2 == .landed)
    }

    // Nothing authored; the event and the Night Card line name the repository.
    @Test("A Feature Branch absent with no recorded landing is indeterminate")
    func absentBranchWithNoLandingIsIndeterminate() async throws {
        let backend = GateGitFixture(name: "p99-indeterminate")
        await backend.initRepo()
        _ = try await backend.commit(message: "init")
        // No `yh-proj-ghost-branch` ever created.

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        _ = try insertGateFeature(
            journal, issueID: "FEAT-GHOST-BRANCH", branch: "yh-proj-ghost-branch", repositories: ["backend"]
        )

        let repositories = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: backend.path, role: .backend)
        ])
        let authoring = ScriptedFeatureAuthoring(outcome: .authored)

        let invocation = EngineInvocation(
            act: .author, mode: .rehearsal, nightStart: gateNightStart, journal: journal,
            trigger: .forced, runID: RunID(), repositories: repositories,
            work: AuthorAct(predecessorGate: PredecessorAncestryGate(), authoring: authoring).work
        )
        try await invocation.run()

        #expect(!authoring.wasCalled)
        let events = try journal.events()
        let indeterminate = try #require(events.first { $0.type == .authoringPredecessorIndeterminate })
        guard case .authoringPredecessorIndeterminate(let issueID, let repos) = indeterminate.event else {
            Issue.record("expected authoringPredecessorIndeterminate")
            return
        }
        #expect(issueID == "FEAT-GHOST-BRANCH")
        #expect(repos == ["backend"])

        let line = try #require(NightCardMaintenance.authoringLine(for: indeterminate.event))
        #expect(line.contains("FEAT-GHOST-BRANCH"))
        #expect(line.contains("backend"))
    }

    // The gate reads feature_repository, never Cards.
    @Test("Touched repositories survive a Card's repository row disappearing")
    func touchedRepositoriesSurviveCardRemoval() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-SURVIVES", branch: "yh-proj-survives", repositories: ["backend"]
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        try insertGateCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend")

        // The Card disappears (cancelled, adopted elsewhere) — its row is removed entirely.
        try journal.write { db in
            try db.execute(sql: "DELETE FROM card WHERE issue_id = ?", arguments: ["BACK-1"])
        }

        let touched = try journal.touchedRepositories(featureID: featureID)
        #expect(touched == ["backend"])
    }

    // A later call for the same repository never overwrites the commit.
    @Test("recordLanding is first-observation-wins")
    func recordLandingIsFirstObservationWins() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-FIRST-WINS", branch: "yh-proj-first-wins", repositories: ["backend"]
        )

        let firstInserted = try journal.recordLanding(
            featureID: featureID, repository: "backend", mainlineCommit: "aaa"
        )
        let secondInserted = try journal.recordLanding(
            featureID: featureID, repository: "backend", mainlineCommit: "bbb"
        )

        #expect(firstInserted)
        #expect(!secondInserted)
        #expect(try journal.landings(featureID: featureID)["backend"] == "aaa")
    }

    @Test("An in-flight Feature (open Cycle) is never picked as the predecessor")
    func inFlightFeatureIsNeverThePredecessor() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try insertGateFeature(journal, issueID: "FEAT-6", branch: "yh-proj-inflight", inFlight: true)

        let walk = try journal.predecessorFeature()

        #expect(walk.predecessor == nil)
        #expect(walk.skippedReleased.isEmpty)
    }

    // Through AuthorAct: not landed skips authoring, records the quiet reason, no Attempt or Worktree.
    @Test("End to end through AuthorAct: not landed skips authoring")
    func endToEndThroughAuthorActSkipsAuthoring() async throws {
        let backend = GateGitFixture(name: "gate-e2e-backend")
        await backend.initRepo()
        _ = try await backend.commit(message: "init")
        _ = await backend.run(["checkout", "-b", "yh-proj-e2e"])
        _ = try await backend.commit(filename: "feat.txt", content: "feat", message: "feature commit")
        _ = await backend.run(["checkout", "main"])
        // Not merged.

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-7", branch: "yh-proj-e2e", repositories: ["backend"]
        )
        let cycleID = try gateCycleID(journal, featureID: featureID)
        try insertGateCard(journal, cycleID: cycleID, issueID: "BACK-1", repository: "backend")

        let repositories = ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: backend.path, role: .backend)
        ])
        let authoring = ScriptedFeatureAuthoring(outcome: .authored)

        let invocation = EngineInvocation(
            act: .author, mode: .rehearsal, nightStart: gateNightStart, journal: journal,
            trigger: .forced, runID: RunID(), repositories: repositories,
            work: AuthorAct(predecessorGate: PredecessorAncestryGate(), authoring: authoring).work
        )
        try await invocation.run()

        #expect(!authoring.wasCalled)

        let events = try journal.events()
        let quiet = try #require(events.first { $0.type == .authoringPredecessorNotLanded })
        guard case .authoringPredecessorNotLanded(let issueID, let repos) = quiet.event else {
            Issue.record("expected authoringPredecessorNotLanded")
            return
        }
        #expect(issueID == "FEAT-7")
        #expect(repos == ["backend"])

        let attemptCount = try journal.write { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attempt") } ?? 0
        let worktreeCount = try journal.write { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM worktree")
        } ?? 0
        #expect(attemptCount == 0)
        #expect(worktreeCount == 0)
    }
}
