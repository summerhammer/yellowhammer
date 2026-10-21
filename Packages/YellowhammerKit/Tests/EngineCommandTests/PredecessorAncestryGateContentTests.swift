import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

// feature-authoring/select-the-next-feature #merge-test, #net-zero-branch, #tested-tip and the Observed Merge
// recording and indeterminate-read criteria (OQ164): a predecessor merged with Squash and merge or Rebase and
// merge opens the gate; the evidence of each Observed Merge is recorded; the commit the land Act recorded is the
// tip tested; the landed pin goes once the merge is observed. Real git, local only.

private let gateBranch = "yh-gate-feature"

/// A repository whose `yh-gate-feature` branch has two commits (a new file and an edit of `shared.txt`);
/// `main` is left checked out at the base. Returns the branch tip.
private func populateFeatureRepository(_ repo: borrowing GateGitFixture) async throws -> String {
    await repo.initRepo()
    _ = try await repo.commit(filename: "shared.txt", content: "base\nline two\nline three\n", message: "init")
    _ = await repo.run(["checkout", "-b", gateBranch])
    _ = try await repo.commit(filename: "feat.txt", content: "feature\n", message: "add feat")
    let tip = try await repo.commit(
        filename: "shared.txt", content: "base\nline two\nfeature line three\n", message: "edit shared"
    )
    _ = await repo.run(["checkout", "main"])
    return tip
}

private func squashMerge(_ repo: borrowing GateGitFixture) async {
    _ = await repo.run(["merge", "--squash", gateBranch])
    _ = await repo.run(["commit", "-m", "squash of \(gateBranch)"])
}

private func repositories(_ repo: borrowing GateGitFixture) -> ProjectRepositories {
    ProjectRepositories(workingRepos: [Repo(name: "backend", path: repo.path, role: .backend)])
}

/// Pins `tip` at `refs/yellowhammer/landed/<branch>`, as the land Act does when it records the commit.
private func pinLandedTip(_ tip: String, in repo: borrowing GateGitFixture) async {
    _ = await LandedTipPin().pin(commit: tip, branch: FeatureBranch(name: gateBranch), repositoryPath: repo.path)
}

private func landedPin(in repo: borrowing GateGitFixture) async -> String? {
    await LandedTipPin().pinnedCommit(branch: FeatureBranch(name: gateBranch), repositoryPath: repo.path)
}

@Suite("Predecessor gate: content merge test and Observed Merge evidence")
struct PredecessorAncestryGateContentTests {
    @Test("A squash merge opens the gate with content evidence, and its landed pin is deleted")
    func squashMergeOpensTheGate() async throws {
        let repo = GateGitFixture(name: "content-squash")
        let tip = try await populateFeatureRepository(repo)
        await squashMerge(repo)
        await pinLandedTip(tip, in: repo)
        #expect(await landedPin(in: repo) == tip)

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-SQ", branch: gateBranch, repositories: ["backend"], landedCommits: ["backend": tip]
        )
        let closure = ScriptedPostMergeClosure()
        let (context, _) = try makeGateContext(journal, repositories: repositories(repo))

        let outcome = try await PredecessorAncestryGate(closure: closure).check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .landed)
        #expect(closure.callCount == 1)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .content])
        let mainHead = await repo.run(["rev-parse", "main"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try journal.landings(featureID: featureID) == ["backend": mainHead])
        #expect(await landedPin(in: repo) == nil)
        #expect(try journal.events(ofType: .landedPinFailed).isEmpty)
    }

    @Test("A rebase merge opens the gate with content evidence, from the recorded commit alone")
    func rebaseMergeOpensTheGate() async throws {
        let repo = GateGitFixture(name: "content-rebase")
        let tip = try await populateFeatureRepository(repo)
        _ = try await repo.commit(filename: "other.txt", content: "other\n", message: "unrelated mainline commit")
        _ = await repo.run(["cherry-pick", "\(gateBranch)~1", gateBranch])
        // The branch ref is gone from the repository (its name is still recorded): only the recorded commit is
        // left to test.
        _ = await repo.run(["branch", "-D", gateBranch])

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-RB", branch: gateBranch, repositories: ["backend"],
            landedCommits: ["backend": tip]
        )
        let (context, _) = try makeGateContext(journal, repositories: repositories(repo))

        let outcome = try await PredecessorAncestryGate().check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .landed)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .content])
    }

    @Test("A merge commit records ancestry evidence and no conflict or content read is needed")
    func mergeCommitRecordsAncestry() async throws {
        let repo = GateGitFixture(name: "content-merge-commit")
        let tip = try await populateFeatureRepository(repo)
        _ = await repo.run(["merge", "--no-ff", "-m", "merge", gateBranch])

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-MC", branch: gateBranch, repositories: ["backend"], landedCommits: ["backend": tip]
        )
        let (context, _) = try makeGateContext(journal, repositories: repositories(repo))

        let outcome = try await PredecessorAncestryGate().check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .landed)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .ancestry])
    }

    @Test("A Feature pushed before commits were recorded falls back to the Feature Branch name")
    func noRecordedCommitFallsBackToTheBranch() async throws {
        let repo = GateGitFixture(name: "content-fallback")
        _ = try await populateFeatureRepository(repo)
        await squashMerge(repo)

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-FB", branch: gateBranch, repositories: ["backend"]
        )
        let (context, _) = try makeGateContext(journal, repositories: repositories(repo))

        let outcome = try await PredecessorAncestryGate().check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .landed)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .content])
    }

    @Test("A squash merge after mainline moved on to unrelated lines of the same file still passes")
    func squashAfterUnrelatedMainlineEditPasses() async throws {
        let repo = GateGitFixture(name: "content-unrelated")
        let tip = try await populateFeatureRepository(repo)
        await squashMerge(repo)
        _ = try await repo.commit(
            filename: "shared.txt", content: "edited base\nline two\nfeature line three\n", message: "edit line one"
        )

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-UN", branch: gateBranch, repositories: ["backend"], landedCommits: ["backend": tip]
        )
        let (context, _) = try makeGateContext(journal, repositories: repositories(repo))

        let outcome = try await PredecessorAncestryGate().check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .landed)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .content])
    }

    @Test("A net-zero branch (a commit and its revert) stays closed")
    func netZeroBranchStaysClosed() async throws {
        let repo = GateGitFixture(name: "content-net-zero")
        await repo.initRepo()
        _ = try await repo.commit(filename: "shared.txt", content: "base\n", message: "init")
        _ = await repo.run(["checkout", "-b", gateBranch])
        _ = try await repo.commit(filename: "feat.txt", content: "feature\n", message: "add feat")
        _ = await repo.run(["revert", "--no-edit", "HEAD"])
        let tip = await repo.run(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = await repo.run(["checkout", "main"])

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-NZ", branch: gateBranch, repositories: ["backend"], landedCommits: ["backend": tip]
        )
        let closure = ScriptedPostMergeClosure()
        let (context, _) = try makeGateContext(journal, repositories: repositories(repo))

        let outcome = try await PredecessorAncestryGate(closure: closure).check(context, unmergedFeaturesMax: 1)

        #expect(namedUnmerged(outcome) == [NamedUnmerged("FEAT-NZ", ["backend"])])
        #expect(try journal.landings(featureID: featureID).isEmpty)
        #expect(closure.callCount == 0)
    }

    @Test("A content test that lapsed before observation stays closed and reports the Mainline Conflict once")
    func lapsedContentTestStaysClosed() async throws {
        let repo = GateGitFixture(name: "content-lapsed")
        let tip = try await populateFeatureRepository(repo)
        await squashMerge(repo)
        _ = try await repo.commit(
            filename: "shared.txt", content: "base\nline two\nlater line three\n", message: "overwrite line three"
        )
        await pinLandedTip(tip, in: repo)

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-LP", branch: gateBranch, repositories: ["backend"], landedCommits: ["backend": tip]
        )
        let (context, _) = try makeGateContext(journal, repositories: repositories(repo))

        let outcome = try await PredecessorAncestryGate().check(context, unmergedFeaturesMax: 1)

        #expect(namedUnmerged(outcome) == [NamedUnmerged("FEAT-LP", ["backend"])])
        #expect(try journal.landings(featureID: featureID).isEmpty)
        #expect(try journal.events(ofType: .mainlineConflictDetected).count == 1)
        // No Observed Merge, so the pin stays: the commit must survive until it is observed.
        #expect(await landedPin(in: repo) == tip)
    }

    @Test("A recorded content Observed Merge is read, not re-tested, when a later mainline edit would fail it")
    func recordedContentMergeIsNotRetested() async throws {
        let repo = GateGitFixture(name: "content-recorded")
        let tip = try await populateFeatureRepository(repo)
        await squashMerge(repo)

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-RC", branch: gateBranch, repositories: ["backend"], landedCommits: ["backend": tip]
        )
        let closure = ScriptedPostMergeClosure()
        let gate = PredecessorAncestryGate(closure: closure)
        let (context1, _) = try makeGateContext(journal, repositories: repositories(repo))
        #expect(try await gate.check(context1, unmergedFeaturesMax: 1) == .landed)
        let recorded = try journal.landings(featureID: featureID)

        _ = try await repo.commit(
            filename: "shared.txt", content: "base\nline two\nlater line three\n", message: "overwrite line three"
        )
        try journal.releaseActLease(runID: context1.runID)
        let (context2, _) = try makeGateContext(journal, repositories: repositories(repo))
        let outcome = try await gate.check(context2, unmergedFeaturesMax: 1)

        #expect(outcome == .landed)
        #expect(try journal.landings(featureID: featureID) == recorded)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .content])
        #expect(closure.callCount == 1)
        #expect(try journal.events(ofType: .mainlineConflictDetected).isEmpty)
    }

    @Test("The recorded commit is tested even when the branch has later commits")
    func recordedCommitIsTestedNotTheLaterBranch() async throws {
        let repo = GateGitFixture(name: "content-later-commits")
        let tip = try await populateFeatureRepository(repo)
        await squashMerge(repo)
        _ = await repo.run(["checkout", gateBranch])
        _ = try await repo.commit(filename: "later.txt", content: "later\n", message: "after the push")
        _ = await repo.run(["checkout", "main"])

        // With the pushed commit recorded, the squash is found although the branch has moved on.
        let recordedFixture = try OutboxJournalFixture()
        let recordedJournal = try recordedFixture.open()
        let recordedID = try insertGateFeature(
            recordedJournal, issueID: "FEAT-LC", branch: gateBranch, repositories: ["backend"],
            landedCommits: ["backend": tip]
        )
        let (recordedContext, _) = try makeGateContext(recordedJournal, repositories: repositories(repo))
        #expect(try await PredecessorAncestryGate().check(recordedContext, unmergedFeaturesMax: 1) == .landed)
        #expect(try recordedJournal.landingEvidence(featureID: recordedID) == ["backend": .content])

        // Without it the branch name is read, and the branch carries a change mainline never received.
        let unrecordedFixture = try OutboxJournalFixture()
        let unrecordedJournal = try unrecordedFixture.open()
        let unrecordedID = try insertGateFeature(
            unrecordedJournal, issueID: "FEAT-NC", branch: gateBranch, repositories: ["backend"]
        )
        let (unrecordedContext, _) = try makeGateContext(unrecordedJournal, repositories: repositories(repo))
        let outcome = try await PredecessorAncestryGate().check(unrecordedContext, unmergedFeaturesMax: 1)
        #expect(namedUnmerged(outcome) == [NamedUnmerged("FEAT-NC", ["backend"])])
        #expect(try unrecordedJournal.landings(featureID: unrecordedID).isEmpty)
    }

    @Test("Branch and pin both deleted after an Observed Merge does not re-close the gate")
    func deletedBranchAndPinDoNotReCloseTheGate() async throws {
        let repo = GateGitFixture(name: "content-deleted-refs")
        let tip = try await populateFeatureRepository(repo)
        await squashMerge(repo)
        await pinLandedTip(tip, in: repo)

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-DR", branch: gateBranch, repositories: ["backend"], landedCommits: ["backend": tip]
        )
        let gate = PredecessorAncestryGate()
        let (context1, _) = try makeGateContext(journal, repositories: repositories(repo))
        #expect(try await gate.check(context1, unmergedFeaturesMax: 1) == .landed)
        #expect(await landedPin(in: repo) == nil)

        _ = await repo.run(["branch", "-D", gateBranch])
        _ = await repo.run(["reflog", "expire", "--expire=now", "--all"])
        _ = await repo.run(["gc", "--prune=now", "--quiet"])
        try journal.releaseActLease(runID: context1.runID)
        let (context2, _) = try makeGateContext(journal, repositories: repositories(repo))
        let outcome = try await gate.check(context2, unmergedFeaturesMax: 1)

        #expect(outcome == .landed)
        #expect(try journal.landingEvidence(featureID: featureID) == ["backend": .content])
    }

    @Test("A pin that cannot be deleted is Journal-only and never changes the outcome")
    func unpinFailureIsJournalOnly() async throws {
        let repo = GateGitFixture(name: "content-unpin-fails")
        let tip = try await populateFeatureRepository(repo)
        await squashMerge(repo)

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-UF", branch: gateBranch, repositories: ["backend"], landedCommits: ["backend": tip]
        )
        let gate = PredecessorAncestryGate(landedTipPin: LandedTipPin(git: GitRunner(executablePath: "/usr/bin/false")))
        let (context, _) = try makeGateContext(journal, repositories: repositories(repo))

        let outcome = try await gate.check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .landed)
        #expect(try journal.landings(featureID: featureID).keys.sorted() == ["backend"])
        let failures = try journal.events(ofType: .landedPinFailed)
        #expect(failures.count == 1)
        guard case .landedPinFailed(_, let repository, let branch, let commit, let operation, _) = failures[0].event
        else {
            Issue.record("expected landedPinFailed")
            return
        }
        #expect(repository == "backend")
        #expect(branch == gateBranch)
        #expect(commit == tip)
        #expect(operation == .unpin)
    }

    @Test("An in-flight Feature whose Cycle has not landed is never tested")
    func unlandedInFlightCycleIsNeverTested() async throws {
        let repo = GateGitFixture(name: "content-in-flight")
        let tip = try await populateFeatureRepository(repo)
        await squashMerge(repo)

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-IF", branch: gateBranch, repositories: ["backend"], inFlight: true,
            landedCommits: ["backend": tip]
        )
        let (context, _) = try makeGateContext(journal, repositories: repositories(repo))

        let outcome = try await PredecessorAncestryGate().check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .landed)
        #expect(try journal.landings(featureID: featureID).isEmpty)
        #expect(try journal.events(ofType: .predecessorAncestryObserved).isEmpty)
    }
}

// The indeterminate read and the no-recorded-branch fault, both through an author Act (OQ164).
@Suite("Predecessor gate: unresolvable tip and Journal fault")
struct PredecessorAncestryGateUnresolvedTests {
    @Test("An unresolvable tip with no Observed Merge is indeterminate, and the Act authors nothing")
    func unresolvableTipIsIndeterminate() async throws {
        let repo = GateGitFixture(name: "unresolved-tip")
        _ = try await populateFeatureRepository(repo)
        _ = await repo.run(["branch", "-D", gateBranch])
        let neverPushed = String(repeating: "ab", count: 20)

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        _ = try insertGateFeature(
            journal, issueID: "FEAT-IN", branch: gateBranch, repositories: ["backend"],
            landedCommits: ["backend": neverPushed]
        )
        let authoring = ScriptedFeatureAuthoring(outcome: .authored)
        let invocation = EngineInvocation(
            act: .author, mode: .rehearsal, nightStart: gateNightStart, journal: journal, trigger: .scheduled,
            runID: RunID(), repositories: repositories(repo),
            work: AuthorAct(predecessorGate: PredecessorAncestryGate(), authoring: authoring).work
        )

        try await invocation.run()

        #expect(!authoring.wasCalled)
        let events = try journal.events(ofType: .authoringPredecessorIndeterminate)
        #expect(events.count == 1)
        #expect(
            events[0].event == .authoringPredecessorIndeterminate(featureIssueID: "FEAT-IN", repositories: ["backend"])
        )
        #expect(try journal.events().map(\.type).last == .actEnded)
    }

    @Test("A recorded commit with no recorded Feature Branch is a fault; the Worktree name does not stand in")
    func lostCommitWithoutARecordedBranchIsAFault() async throws {
        let repo = GateGitFixture(name: "unresolved-no-branch")
        _ = try await populateFeatureRepository(repo)
        await squashMerge(repo)
        let lost = String(repeating: "cd", count: 20)

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        // A live branch named like the Feature's Worktree exists and would test as merged, but none was
        // recorded for the repository.
        _ = try insertGateFeature(
            journal, issueID: "FEAT-LN", branch: gateBranch, repositories: ["backend"], recordBranch: false,
            landedCommits: ["backend": lost]
        )
        let (context, _) = try makeGateContext(journal, repositories: repositories(repo))

        await #expect(throws: PredecessorAncestryGateError.predecessorBranchMissing(featureIssueID: "FEAT-LN")) {
            _ = try await PredecessorAncestryGate().check(context, unmergedFeaturesMax: 1)
        }
    }

    @Test("A recorded commit the repository lost is indeterminate even when the recorded branch is live and merged")
    func lostCommitIsNeverReplacedByALiveBranch() async throws {
        let repo = GateGitFixture(name: "unresolved-lost-commit-live-branch")
        _ = try await populateFeatureRepository(repo)
        await squashMerge(repo)
        let lost = String(repeating: "cd", count: 20)

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        // The branch is recorded and live, and the content test would pass through it; but a commit was
        // recorded, so the branch (which may carry commits added on GitHub) is never consulted.
        let featureID = try insertGateFeature(
            journal, issueID: "FEAT-LB", branch: gateBranch, repositories: ["backend"],
            landedCommits: ["backend": lost]
        )
        let (context, _) = try makeGateContext(journal, repositories: repositories(repo))

        let outcome = try await PredecessorAncestryGate().check(context, unmergedFeaturesMax: 1)

        #expect(outcome == .indeterminate(predecessorIssueID: "FEAT-LB", repositories: ["backend"]))
        #expect(try journal.landings(featureID: featureID).isEmpty)
        #expect(try journal.events(ofType: .mainlineConflictDetected).isEmpty)
    }

    @Test("A repository in N with no recorded Feature Branch and no recorded commit is a fault, not a quiet Night")
    func noRecordedBranchIsAFault() async throws {
        let repo = GateGitFixture(name: "unresolved-fault")
        _ = try await populateFeatureRepository(repo)
        await squashMerge(repo)

        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        // The Worktree name is set and a branch of that name exists, but none was ever recorded for the
        // repository: the name must not stand in for the missing record.
        _ = try insertGateFeature(
            journal, issueID: "FEAT-FT", branch: gateBranch, repositories: ["backend"], recordBranch: false
        )
        let (context, _) = try makeGateContext(journal, repositories: repositories(repo))
        await #expect(throws: PredecessorAncestryGateError.predecessorBranchMissing(featureIssueID: "FEAT-FT")) {
            _ = try await PredecessorAncestryGate().check(context, unmergedFeaturesMax: 1)
        }
        try journal.releaseActLease(runID: context.runID)

        let authoring = ScriptedFeatureAuthoring(outcome: .authored)
        let invocation = EngineInvocation(
            act: .author, mode: .rehearsal, nightStart: gateNightStart, journal: journal, trigger: .scheduled,
            runID: RunID(), repositories: repositories(repo),
            work: AuthorAct(predecessorGate: PredecessorAncestryGate(), authoring: authoring).work
        )
        await #expect(throws: PredecessorAncestryGateError.predecessorBranchMissing(featureIssueID: "FEAT-FT")) {
            try await invocation.run()
        }

        // The Act ended incomplete, which the halted path reports to the Operator; neither quiet-Night line
        // was written and nothing was authored.
        #expect(!authoring.wasCalled)
        let types = try journal.events().map(\.type)
        #expect(types.last == .actIncomplete)
        #expect(!types.contains(.authoringSkippedUnmergedStackFull))
        #expect(!types.contains(.authoringPredecessorIndeterminate))
        #expect(!types.contains(.actEnded))
    }
}
