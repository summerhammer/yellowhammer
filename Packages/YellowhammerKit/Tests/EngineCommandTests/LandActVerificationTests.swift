import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// roadmap P10.5: Verification runs after every lane's push and before any pull request is opened, because
// a pull request body is written once and must carry the clause report. A Verification that did not
// complete leaves the Cycle unlanded, and the next land firing retries.

private struct ThrowingVerification: FeatureVerifying {
    struct Failure: Error, CustomStringConvertible {
        var description: String { "no verifier answered" }
    }

    func verify(_ context: LandActFeatureContext) async throws -> VerificationVerdict {
        throw Failure()
    }
}

private struct RecordedStep {
    let repository: String?
    let outcome: LandStepOutcome
    let detail: String?
}

private func landStepOutcomes(_ journal: JournalStore, step: LandStep) throws -> [RecordedStep] {
    try journal.events(ofType: .landStep).compactMap { record in
        guard case .landStep(let found, let repository, let outcome, let detail) = record.event, found == step else {
            return nil
        }
        return RecordedStep(repository: repository, outcome: outcome, detail: detail)
    }
}

@Suite("Land Act: Verification before pull requests (P10.5)")
struct LandActVerificationTests {
    private func world(mode: NightMode = .real) async throws -> VerificationWorld {
        let world = try await VerificationWorld(
            cards: [VerificationCard("BACK-1", "backend", .done), VerificationCard("MOB-1", "mobile", .done)],
            mode: mode
        )
        try world.addClause(issue: "BACK-1", cid: "c1")
        try world.addClause(issue: "MOB-1", cid: "c1")
        for repository in ["backend", "mobile"] {
            try world.journal.recordWorktree(
                featureID: world.featureID, repository: repository, worktreeID: "wt-\(repository)",
                path: "/tmp/\(repository)", runID: world.featureContext.act.runID
            )
        }
        return world
    }

    @Test("A Verification fault skips every pull request, keeps the Worktrees, leaves the Cycle unlanded")
    func faultSkipsPullRequests() async throws {
        let world = try await world()
        let log = LandCallLog()
        let act = LandAct(
            mergeTest: StubMergeTest(log: log), push: StubPush(log: log),
            openPullRequest: StubPullRequest(log: log), verification: ThrowingVerification(),
            archiveCycle: StubArchiveCycle(log: log)
        )

        do {
            try await act.run(world.featureContext.act)
            Issue.record("expected the fault to be thrown")
        } catch let error as LandActError {
            #expect(error == .lanesFailed(["FEAT-1": "no verifier answered"]))
        }

        #expect(log.all.filter { $0.hasPrefix("push") }.count == 2)
        #expect(!log.all.contains { $0.hasPrefix("openPullRequest") })
        #expect(!log.all.contains("archiveCycle"))
        let pullRequests = try landStepOutcomes(world.journal, step: .openPullRequest)
        #expect(pullRequests.count == 2)
        #expect(pullRequests.allSatisfy { $0.outcome == .skipped && $0.detail == "Verification did not complete" })
        #expect(try heldWorktreeIDs(world.journal, featureID: world.featureID) == ["backend": true, "mobile": true])
        #expect(try !world.journal.isCycleLanded(cycleID: world.cycleID))
        #expect(try landStepOutcomes(world.journal, step: .verification).map(\.outcome) == [.failed])
    }

    @Test("A lane that faulted before Verification stops Verification and every pull request")
    func laneFaultStopsVerification() async throws {
        let world = try await world()
        let log = LandCallLog()
        let act = LandAct(
            mergeTest: StubMergeTest(log: log), push: StubPush(log: log, throwing: ["backend"]),
            openPullRequest: StubPullRequest(log: log),
            verification: StubVerification(log: log, verdict: VerificationVerdict(allClausesMet: true))
        )

        await #expect(throws: LandActError.self) { try await act.run(world.featureContext.act) }

        #expect(!log.all.contains("verification"))
        #expect(!log.all.contains { $0.hasPrefix("openPullRequest") })
        #expect(try landStepOutcomes(world.journal, step: .verification).isEmpty)
        #expect(try !world.journal.isCycleLanded(cycleID: world.cycleID))
    }

    @Test("No Verification seam: pull requests open as before, and the three Feature steps are not wired")
    func nilSeamKeepsTheOldBehaviour() async throws {
        let world = try await world()
        let log = LandCallLog()
        let act = LandAct(
            mergeTest: StubMergeTest(log: log), push: StubPush(log: log), openPullRequest: StubPullRequest(log: log)
        )

        try await act.run(world.featureContext.act)

        #expect(log.all.filter { $0.hasPrefix("openPullRequest") }.count == 2)
        // No Workspace is bound here, so release is skipped for that reason — not for Verification's.
        let releases = try landStepOutcomes(world.journal, step: .releaseWorktree)
        #expect(releases.allSatisfy { $0.detail == "no Workspace bound" })
        #expect(try landStepOutcomes(world.journal, step: .verification).map(\.outcome) == [.notWired])
        #expect(try world.journal.isCycleLanded(cycleID: world.cycleID))
    }

    @Test("A verdict of unmet clauses returns the Feature after the pull requests opened")
    func unmetVerdictStillOpensPullRequests() async throws {
        let world = try await world()
        let log = LandCallLog()
        let act = LandAct(
            mergeTest: StubMergeTest(log: log), push: StubPush(log: log),
            openPullRequest: StubPullRequest(log: log),
            verification: StubVerification(
                log: log, verdict: VerificationVerdict(allClausesMet: false, unmetClauses: ["BACK-1 c1"])
            ),
            returnFeature: StubReturnFeature(log: log)
        )

        try await act.run(world.featureContext.act)

        let calls = log.all
        let returned = try #require(calls.firstIndex(of: "returnFeature"))
        #expect(try #require(calls.lastIndex { $0.hasPrefix("openPullRequest") }) < returned)
        let firstPullRequest = try #require(calls.firstIndex { $0.hasPrefix("openPullRequest") })
        #expect(try #require(calls.firstIndex(of: "verification")) < firstPullRequest)
    }

    @Test("Rehearsal runs Verification from the fixture, never an agent CLI, and stops at the pull request boundary")
    func rehearsalRunsVerificationAndStopsAtTheBoundary() async throws {
        let world = try await world(mode: .rehearsal)
        let log = LandCallLog()
        let rehearsal = RehearsalDispatch()
        let verification = FeatureVerification(
            resolver: verificationResolver(primary: routeOther), dispatch: rehearsal, citations: FakeCitationResolver()
        )
        let act = LandAct(
            mergeTest: StubMergeTest(log: log), push: StubPush(log: log),
            openPullRequest: StubPullRequest(log: log), verification: verification
        )

        try await act.run(world.featureContext.act)

        #expect(!log.all.contains { $0.hasPrefix("push") || $0.hasPrefix("openPullRequest") })
        #expect(rehearsal.answered.map(\.pass) == [.verifier])
        #expect(try landStepOutcomes(world.journal, step: .verification).map(\.outcome) == [.completed])
        let boundaries = try landStepOutcomes(world.journal, step: .openPullRequest).map(\.outcome)
        #expect(boundaries == [.rehearsalBoundary, .rehearsalBoundary])
        let recorded = try #require(try world.journal.featureVerification(cycleID: world.cycleID))
        #expect(recorded.clauses.map(\.verdict) == [.met, .met])
        let dispatched = try world.journal.events(ofType: .authoringDispatched).map(\.event)
        #expect(dispatched == [
            .authoringDispatched(
                pass: .verifier, route: routeOther.description, ordinal: 1, fixture: "verifier-reported.json"
            )
        ])
    }

    @Test("A scripted verifier-failed fixture exhausts the table: Verification faults in a rehearsal too")
    func rehearsalVerifierFailedFaults() async throws {
        let world = try await world(mode: .rehearsal)
        let verification = FeatureVerification(
            resolver: verificationResolver(primary: routeOther),
            dispatch: RehearsalDispatch(script: [.verifier: .verifierFailed]), citations: FakeCitationResolver()
        )
        let act = LandAct(verification: verification)

        await #expect(throws: LandActError.self) { try await act.run(world.featureContext.act) }

        #expect(try !world.journal.isCycleLanded(cycleID: world.cycleID))
        #expect(try world.journal.featureVerification(cycleID: world.cycleID) == nil)
    }
}
