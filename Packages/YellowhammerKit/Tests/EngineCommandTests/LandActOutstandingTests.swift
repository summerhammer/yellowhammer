import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// issue #405, spec story landing/open-one-pull-request-per-repository: a push or a pull request the seam
// reports as refused or not opened (no throw) is outstanding, not a fault. The Act ends normally, the
// Cycle stays unlanded, and the next land firing resumes the outstanding steps.

private func fire(_ act: LandAct, journal: JournalStore, runID: RunID) async throws {
    let invocation = EngineInvocation(
        act: .land, mode: .real, nightStart: landNightStart, journal: journal, trigger: .scheduled,
        runID: runID, workspace: ReconcilerFakeWorkspace(), work: act.work
    )
    try await invocation.run()
}

private func landAct(
    _ log: LandCallLog, push: StubPush? = nil, pullRequest: StubPullRequest? = nil
) -> LandAct {
    LandAct(
        mergeTest: StubMergeTest(log: log),
        push: push ?? StubPush(log: log),
        openPullRequest: pullRequest ?? StubPullRequest(log: log),
        verification: StubVerification(log: log, verdict: VerificationVerdict(allClausesMet: true)),
        archiveCycle: StubArchiveCycle(log: log)
    )
}

@Suite("Land Act: an outstanding push or pull request leaves the Cycle unlanded (#405)")
struct LandActOutstandingTests {
    @Test("A refused push with no Verification seam wired still opens no pull request and holds both Worktrees")
    func pushOutstandingWithoutVerification() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLandLease(journal, runID: runID)
        let land = try LandFixture.make(journal, runID: runID)

        let log = LandCallLog()
        let act = LandAct(
            mergeTest: StubMergeTest(log: log),
            push: StubPush(log: log, notPushed: ["backend"]),
            openPullRequest: StubPullRequest(log: log),
            archiveCycle: StubArchiveCycle(log: log)
        )
        try await fire(act, journal: journal, runID: runID)

        #expect(!log.all.contains { $0.hasPrefix("openPullRequest") })
        #expect(!log.all.contains("archiveCycle"))
        #expect(try heldWorktreeIDs(journal, featureID: land.featureID) == ["backend": true, "mobile": true])
        #expect(try !journal.isCycleLanded(cycleID: land.cycleID))
        #expect(try journal.events(ofType: .cycleLanded).isEmpty)
    }

    @Test("A pull request reported not opened holds that Worktree, releases the other, and leaves the Cycle unlanded")
    func pullRequestNotOpened() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let runID = RunID()
        try claimLandLease(journal, runID: runID)
        let land = try LandFixture.make(journal, runID: runID)

        let log = LandCallLog()
        let act = landAct(log, pullRequest: StubPullRequest(log: log, notOpened: ["backend"]))
        try await fire(act, journal: journal, runID: runID)

        #expect(log.all.filter { $0 == "verification" }.count == 1)
        #expect(log.all.contains("openPullRequest:backend"))
        #expect(log.all.contains("openPullRequest:mobile"))
        #expect(try heldWorktreeIDs(journal, featureID: land.featureID) == ["backend": true, "mobile": false])
        let backendPullRequest = try #require(
            try recordedLandSteps(journal, .openPullRequest, repository: "backend").first
        )
        #expect(backendPullRequest.outcome == .failed)
        let backendRelease = try #require(try recordedLandSteps(journal, .releaseWorktree, repository: "backend").first)
        #expect(backendRelease.outcome == .skipped)
        #expect(backendRelease.detail == "pull request not opened")
        #expect(!log.all.contains("archiveCycle"))
        #expect(try !journal.isCycleLanded(cycleID: land.cycleID))
        #expect(try journal.events(ofType: .cycleLanded).isEmpty)
    }

    @Test("The next firing after a refused push runs Verification once, releases both Worktrees, lands the Cycle once")
    func retryAfterRefusedPush() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let firstRun = RunID()
        try claimLandLease(journal, runID: firstRun)
        let land = try LandFixture.make(journal, runID: firstRun)

        let log = LandCallLog()
        let refusing = landAct(log, push: StubPush(log: log, notPushed: ["backend"]))
        try await fire(refusing, journal: journal, runID: firstRun)
        #expect(try !journal.isCycleLanded(cycleID: land.cycleID))
        #expect(!log.all.contains("verification"))

        try await fire(landAct(log), journal: journal, runID: RunID())

        #expect(try journal.isCycleLanded(cycleID: land.cycleID))
        #expect(try journal.events(ofType: .cycleLanded).count == 1)
        #expect(try heldWorktreeIDs(journal, featureID: land.featureID) == ["backend": false, "mobile": false])
        #expect(log.all.filter { $0 == "verification" }.count == 1)
        #expect(log.all.filter { $0 == "archiveCycle" }.count == 1)
    }

    @Test("The next firing after a pull request not opened does not release the opened lane's Worktree twice")
    func retryAfterPullRequestNotOpened() async throws {
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let firstRun = RunID()
        try claimLandLease(journal, runID: firstRun)
        let land = try LandFixture.make(journal, runID: firstRun)

        let log = LandCallLog()
        let refusing = landAct(log, pullRequest: StubPullRequest(log: log, notOpened: ["backend"]))
        try await fire(refusing, journal: journal, runID: firstRun)
        #expect(try !journal.isCycleLanded(cycleID: land.cycleID))

        try await fire(landAct(log), journal: journal, runID: RunID())

        #expect(try journal.isCycleLanded(cycleID: land.cycleID))
        #expect(try journal.events(ofType: .cycleLanded).count == 1)
        let mobileReleases = try recordedLandSteps(journal, .releaseWorktree, repository: "mobile")
        #expect(mobileReleases.map(\.outcome) == [.completed, .skipped])
        #expect(mobileReleases.last?.detail == "no Worktree held")
        let backendReleases = try recordedLandSteps(journal, .releaseWorktree, repository: "backend")
        #expect(backendReleases.last?.outcome == .completed)
        #expect(try heldWorktreeIDs(journal, featureID: land.featureID) == ["backend": false, "mobile": false])
        #expect(log.all.filter { $0 == "archiveCycle" }.count == 1)
    }

    @Test("A recorded Verification report is reused when a pull request not opened is retried")
    func verificationReportReusedAcrossRetry() async throws {
        let world = try await VerificationWorld(
            cards: [VerificationCard("BACK-1", "backend", .done), VerificationCard("MOB-1", "mobile", .done)]
        )
        try world.addClause(issue: "BACK-1", cid: "c1")
        try world.addClause(issue: "MOB-1", cid: "c1")
        for repository in ["backend", "mobile"] {
            try world.journal.recordWorktree(
                featureID: world.featureID, repository: repository, worktreeID: "wt-\(repository)",
                path: "/tmp/\(repository)", runID: world.featureContext.act.runID
            )
        }
        let dispatch = ScriptedVerifierDispatch([routeOther: .judgeAll()])
        let verification = world.verification(resolver: verificationResolver(primary: routeOther), dispatch: dispatch)
        let log = LandCallLog()

        let refusing = LandAct(
            mergeTest: StubMergeTest(log: log), push: StubPush(log: log),
            openPullRequest: StubPullRequest(log: log, notOpened: ["backend"]), verification: verification
        )
        try await refusing.run(world.featureContext.act)
        #expect(try !world.journal.isCycleLanded(cycleID: world.cycleID))
        #expect(try world.journal.featureVerification(cycleID: world.cycleID) != nil)
        #expect(dispatch.requests.count == 1)

        let healthy = LandAct(
            mergeTest: StubMergeTest(log: log), push: StubPush(log: log),
            openPullRequest: StubPullRequest(log: log), verification: verification
        )
        try await healthy.run(world.featureContext.act)

        #expect(try world.journal.isCycleLanded(cycleID: world.cycleID))
        #expect(dispatch.requests.count == 1)
        #expect(try world.journal.events(ofType: .featureVerified).count == 1)
    }

    @Test("A GitHub push refused for missing credentials leaves the whole Cycle unlanded without a fault")
    func credentialsMissingLeavesCycleUnlanded() async throws {
        let local = TestGitRepo(name: "outstanding-creds-local")
        await local.initRepo(defaultBranch: "main")
        _ = try await local.commit(message: "initial")
        _ = await local.run(["checkout", "-b", "yh-proj-feat"])
        _ = try await local.commit(filename: "feat.txt", content: "feature", message: "feature work")

        let remote = TestGitRepo(name: "outstanding-creds-remote")
        await remote.initRepo(bare: true, defaultBranch: "main")
        await local.addRemote(url: remote.path)

        let repo = Repo(name: "backend", path: local.path, role: .backend, defaultBranch: "main")
        let env = try await Environment.make(repos: [repo])
        await env.board.seed(issue: "FEAT-1", description: nil)
        let (_, cycleID) = try env.setUpFeature()

        struct TokenError: Error {}
        let log = LandCallLog()
        let act = LandAct(
            push: FeatureBranchLanePush(credential: { throw TokenError() }),
            openPullRequest: StubPullRequest(log: log)
        )
        try await act.run(env.context)

        let step = try #require(env.pushStep(repository: "backend"))
        #expect(step.outcome == .failed)
        await #expect(remote.revParse("refs/heads/yh-proj-feat") == nil)
        #expect(!log.all.contains { $0.hasPrefix("openPullRequest") })
        #expect(try !env.journal.isCycleLanded(cycleID: cycleID))
        #expect(try env.journal.events(ofType: .cycleLanded).isEmpty)
    }
}
