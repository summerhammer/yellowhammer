import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

// roadmap P23.5 (spec: feature-authoring/select-the-next-feature, `#unmerged-feature-stack`, `#tested-tip`;
// morning-report/write-the-night-summary): the gate's merge pass over every Feature in the Unmerged Feature Stack
// U, the quiet skip at `unmerged_features_max`, and the landed pin kept while an open Cycle's base names it.
// Fixtures are throwaway git repositories; nothing model-authored is asserted.

/// One backend repository with a Feature Branch per name, each one commit ahead of `main`, unmerged.
private func backendWithBranches(_ name: String, branches: [String]) async throws -> GateGitFixture {
    let backend = GateGitFixture(name: name)
    await backend.initRepo()
    _ = try await backend.commit(message: "init")
    for branch in branches {
        _ = await backend.run(["checkout", "-b", branch, "main"])
        _ = try await backend.commit(filename: "\(branch).txt", content: branch, message: "work on \(branch)")
    }
    _ = await backend.run(["checkout", "main"])
    return backend
}

private func tip(_ repo: borrowing GateGitFixture, _ ref: String) async -> String {
    await repo.run(["rev-parse", ref]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func pinExists(_ repo: borrowing GateGitFixture, branch: String) async -> Bool {
    await repo.run(["show-ref", "--verify", "--quiet", "refs/yellowhammer/landed/\(branch)"]).isSuccess
}

private func backendRepositories(_ repo: borrowing GateGitFixture) -> ProjectRepositories {
    ProjectRepositories(workingRepos: [Repo(name: "backend", path: repo.path, role: .backend)])
}

/// An archived Feature in U whose backend tip is recorded and pinned, as the land Act leaves it.
@discardableResult
private func insertLandedFeature(
    _ journal: JournalStore, _ repo: borrowing GateGitFixture, issueID: String, branch: String
) async throws -> Int64 {
    let commit = await tip(repo, branch)
    _ = await repo.run(["update-ref", "refs/yellowhammer/landed/\(branch)", commit])
    return try insertGateFeature(
        journal, issueID: issueID, branch: branch, repositories: ["backend"], landed: true,
        pushedTips: ["backend": commit]
    )
}

@Suite("The Unmerged Feature Stack gate (P23.5)")
struct UnmergedStackGateTests {
    @Test("Max 3: one verified unmerged Feature in U opens the gate, and the next author Act selects")
    func oneUnmergedFeatureUnderTheBoundSelects() async throws {
        let backend = try await backendWithBranches("stack-one", branches: ["yh-f1"])
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try await insertLandedFeature(journal, backend, issueID: "F1", branch: "yh-f1")
        let authoring = ScriptedFeatureAuthoring(outcome: .authored)

        try await EngineInvocation(
            act: .author, mode: .rehearsal, nightStart: gateNightStart, journal: journal, trigger: .scheduled,
            runID: RunID(), repositories: backendRepositories(backend),
            work: AuthorAct(predecessorGate: PredecessorAncestryGate(), authoring: authoring, unmergedFeaturesMax: 3)
                .work
        ).run()

        #expect(authoring.wasCalled)
        #expect(try journal.unmergedFeatureStack().map(\.feature.issueID) == ["F1"])
        #expect(try journal.events(ofType: .authoringSkippedUnmergedStackFull).isEmpty)
    }

    @Test("Max 3: three unmerged Features fill the stack, named oldest first with each repository and branch")
    func threeUnmergedFeaturesFillTheStack() async throws {
        let backend = try await backendWithBranches("stack-three", branches: ["yh-f1", "yh-f2", "yh-f3"])
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        for index in 1...3 {
            try await insertLandedFeature(journal, backend, issueID: "F\(index)", branch: "yh-f\(index)")
        }
        let (context, _) = try makeGateContext(journal, repositories: backendRepositories(backend))

        let outcome = try await PredecessorAncestryGate().check(context, unmergedFeaturesMax: 3)

        #expect(outcome == .stackFull(features: (1...3).map { index in
            UnmergedStackEntry(
                featureIssueID: "F\(index)", identifier: "F\(index)", unmergedRepositories: ["backend"],
                branches: ["backend": "yh-f\(index)"]
            )
        }))
        #expect(try journal.events(ofType: .predecessorWalkSkippedReleasedFeature).isEmpty)
    }

    @Test("Max 3, three unmerged: the author Act records the skip, the verdict is quiet, the line names every branch")
    func stackFullSkipsAuthoringQuietly() async throws {
        let backend = try await backendWithBranches("stack-skip", branches: ["yh-f1", "yh-f2", "yh-f3"])
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        for index in 1...3 {
            try await insertLandedFeature(journal, backend, issueID: "F\(index)", branch: "yh-f\(index)")
        }
        let authoring = ScriptedFeatureAuthoring(outcome: .authored)

        try await EngineInvocation(
            act: .author, mode: .rehearsal, nightStart: gateNightStart, journal: journal, trigger: .scheduled,
            runID: RunID(), repositories: backendRepositories(backend),
            work: AuthorAct(predecessorGate: PredecessorAncestryGate(), authoring: authoring, unmergedFeaturesMax: 3)
                .work
        ).run()

        #expect(!authoring.wasCalled)
        let skip = try #require(try journal.events(ofType: .authoringSkippedUnmergedStackFull).first)
        guard case .authoringSkippedUnmergedStackFull(let features, let max) = skip.event else {
            Issue.record("expected authoringSkippedUnmergedStackFull")
            return
        }
        #expect(features.map(\.featureIssueID) == ["F1", "F2", "F3"])
        #expect(max == 3)
        let night = try #require(try journal.currentNight())
        #expect(try NightSummary.verdictLine(night: night, journal: journal).contains("did not advance — quiet"))
        let line = try #require(NightCardMaintenance.authoringLine(for: skip.event, journal: journal))
        #expect(line.contains("unmerged Feature stack reached unmerged_features_max (3 unmerged Features:"))
        #expect(line.contains("Not found in mainline: `yh-f1` in backend, `yh-f2` in backend, `yh-f3` in backend."))
        let attempts = try journal.write { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attempt") } ?? 0
        #expect(attempts == 0)
    }

    @Test("Max 3: a Feature in U whose tip cannot be read is indeterminate, though U is under the bound")
    func unreadableTipInUIsIndeterminate() async throws {
        let backend = try await backendWithBranches("stack-unreadable", branches: [])
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        // A branch is recorded, but neither it nor a landed commit exists in the repository.
        try insertGateFeature(journal, issueID: "F1", branch: "yh-gone", repositories: ["backend"], landed: true)
        let (context, _) = try makeGateContext(journal, repositories: backendRepositories(backend))

        let outcome = try await PredecessorAncestryGate().check(context, unmergedFeaturesMax: 3)

        #expect(outcome == .indeterminate(predecessorIssueID: "F1", repositories: ["backend"]))
    }

    // Every Feature in U is tested, not only the most recent archived one: an upper Feature merging does not take
    // a lower, unmerged one out of U (an upper pull request merged first merges into the lower branch, not mainline).
    @Test("Max 1: a merged Feature above an unmerged one leaves the lower Feature alone in U, holding the gate")
    func mergedUpperFeatureKeepsTheLowerInU() async throws {
        let backend = try await backendWithBranches("stack-upper", branches: ["yh-f1", "yh-f2"])
        _ = await backend.run(["merge", "--no-ff", "-m", "merge f2", "yh-f2"])
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try await insertLandedFeature(journal, backend, issueID: "F1", branch: "yh-f1")
        try await insertLandedFeature(journal, backend, issueID: "F2", branch: "yh-f2")
        let (context, _) = try makeGateContext(journal, repositories: backendRepositories(backend))

        let outcome = try await PredecessorAncestryGate().check(context, unmergedFeaturesMax: 1)

        #expect(namedUnmerged(outcome) == [NamedUnmerged("F1", ["backend"])])
        #expect(try journal.unmergedFeatureStack().map(\.feature.issueID) == ["F1"])
    }

    @Test("The closure seam fires once per Feature in U on the first fully merged pass, never again")
    func closureFiresOncePerFeature() async throws {
        let backend = try await backendWithBranches("stack-closure", branches: ["yh-f1", "yh-f2"])
        _ = await backend.run(["merge", "--no-ff", "-m", "merge f1", "yh-f1"])
        _ = await backend.run(["merge", "--no-ff", "-m", "merge f2", "yh-f2"])
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try await insertLandedFeature(journal, backend, issueID: "F1", branch: "yh-f1")
        try await insertLandedFeature(journal, backend, issueID: "F2", branch: "yh-f2")
        let closure = ScriptedPostMergeClosure()
        let gate = PredecessorAncestryGate(closure: closure)

        let (first, _) = try makeGateContext(journal, repositories: backendRepositories(backend))
        #expect(try await gate.check(first, unmergedFeaturesMax: 1) == .open)
        #expect(closure.callCount == 2)
        #expect(try journal.unmergedFeatureStack().isEmpty)

        try journal.releaseActLease(runID: first.runID)
        let (second, _) = try makeGateContext(journal, repositories: backendRepositories(backend))
        #expect(try await gate.check(second, unmergedFeaturesMax: 1) == .open)
        #expect(closure.callCount == 2)
    }
}

@Suite("Merges observed while a Feature is in flight, and the landed pin's lifetime (P23.5)")
struct UnmergedStackInFlightTests {
    // F2 was authored on F1's landed tip and is building; F1's pull request merges with a merge commit.
    @Test("F1 merged while F2 builds: F1's Observed Merge is recorded, F1 leaves U, F2's base keeps F1's pin")
    func mergeObservedWhileAnotherFeatureIsInFlight() async throws {
        let backend = try await backendWithBranches("stack-inflight", branches: ["yh-f1"])
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let f1 = try await insertLandedFeature(journal, backend, issueID: "F1", branch: "yh-f1")
        let f2 = try insertGateFeature(
            journal, issueID: "F2", branch: "yh-f2", repositories: ["backend"], inFlight: true
        )
        let baseCommit = await tip(backend, "yh-f1")
        try journal.recordFeatureBases(featureID: f2, bases: [FeatureBaseRecord(
            repository: "backend", baseRef: "refs/yellowhammer/landed/yh-f1", baseCommit: baseCommit,
            stackedOnFeatureID: f1
        )])
        _ = await backend.run(["merge", "--no-ff", "-m", "merge f1", "yh-f1"])
        let authoring = ScriptedFeatureAuthoring(outcome: .authored)

        try await EngineInvocation(
            act: .author, mode: .rehearsal, nightStart: gateNightStart, journal: journal, trigger: .scheduled,
            runID: RunID(), repositories: backendRepositories(backend),
            work: AuthorAct(predecessorGate: PredecessorAncestryGate(), authoring: authoring, unmergedFeaturesMax: 3)
                .work
        ).run()

        #expect(!authoring.wasCalled)
        #expect(try journal.landings(featureID: f1)["backend"] != nil)
        #expect(try journal.unmergedFeatureStack().isEmpty)
        #expect(try journal.inFlightFeature()?.0.issueID == "F2")
        let types = try journal.events().map(\.type)
        #expect(types.contains(.authoringSkippedFeatureInFlight))
        #expect(!types.contains(.authoringSkippedUnmergedStackFull))
        #expect(await pinExists(backend, branch: "yh-f1"))

        // F2's Cycle archives: the pin its base kept past F1's Observed Merge goes now.
        try journal.write { db in
            try db.execute(
                sql: "UPDATE cycle SET archived_at = ? WHERE feature_id = ?",
                arguments: [JournalStore.timestamp(outboxEpoch), f2]
            )
        }
        let f2Record = try #require(try journal.feature(id: f2))
        await LandedPinRelease(act: nil, runID: nil, nightID: nil).releaseBasePins(
            of: f2Record, repositories: backendRepositories(backend).workingRepos, journal: journal
        )
        #expect(!(await pinExists(backend, branch: "yh-f1")))
    }

    @Test("With no open Cycle naming it, a landed pin is deleted at its Observed Merge")
    func pinDeletedAtObservedMergeWithoutAnOpenBase() async throws {
        let backend = try await backendWithBranches("stack-pin", branches: ["yh-f1"])
        _ = await backend.run(["merge", "--no-ff", "-m", "merge f1", "yh-f1"])
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try await insertLandedFeature(journal, backend, issueID: "F1", branch: "yh-f1")
        #expect(await pinExists(backend, branch: "yh-f1"))
        let (context, _) = try makeGateContext(journal, repositories: backendRepositories(backend))

        #expect(try await PredecessorAncestryGate().check(context, unmergedFeaturesMax: 3) == .open)

        #expect(!(await pinExists(backend, branch: "yh-f1")))
    }

    @Test("An archive leaves a base's pin alone while its Feature has not merged there: it is still the tested tip")
    func archiveKeepsThePinOfAnUnmergedBase() async throws {
        let backend = try await backendWithBranches("stack-keep", branches: ["yh-f1"])
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let f1 = try await insertLandedFeature(journal, backend, issueID: "F1", branch: "yh-f1")
        let f2 = try insertGateFeature(journal, issueID: "F2", branch: "yh-f2", repositories: ["backend"])
        let baseCommit = await tip(backend, "yh-f1")
        try journal.recordFeatureBases(featureID: f2, bases: [FeatureBaseRecord(
            repository: "backend", baseRef: "refs/yellowhammer/landed/yh-f1", baseCommit: baseCommit,
            stackedOnFeatureID: f1
        )])

        let f2Record = try #require(try journal.feature(id: f2))
        await LandedPinRelease(act: nil, runID: nil, nightID: nil).releaseBasePins(
            of: f2Record, repositories: backendRepositories(backend).workingRepos, journal: journal
        )

        #expect(await pinExists(backend, branch: "yh-f1"))
    }
}

@Suite("Repeated stack-full skips in one Night collapse to one line (P23.5)")
struct UnmergedStackSkipCollapseTests {
    @Test("Five skip events in one Night render one line, carrying the latest skip's content")
    func fiveSkipsRenderOneLine() async throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let boards = try await makeBoards()
        let run = RunID()
        _ = try journal.claimActLease(act: .author, runID: run, mode: .rehearsal)
        let night = try journal.openNight(nightStart: nightCardNightStart, mode: .rehearsal, act: .author, runID: run)
            .night
        let outbox = Outbox(journal: journal, board: boards.writing, runID: run, act: .author, nightID: night.id)
        let maintenance = NightCardMaintenance(journal: journal, outbox: outbox, provisioning: boards.provisioning)
        for _ in 1...4 {
            try journal.append(
                stackFullSkip("F1", ["backend", "mobile"]), act: .author, runID: RunID(), nightID: night.id
            )
        }
        try journal.append(.authoringNoWorkAvailable, act: .author, runID: RunID(), nightID: night.id)
        // The last firing saw mobile merged: its content is what the Night renders.
        let latest = stackFullSkip("F1", ["backend"])
        try journal.append(latest, act: .author, runID: RunID(), nightID: night.id)

        let lines = try maintenance.authoringLines(night: night)

        let skipLines = lines.filter { $0.hasPrefix("Authoring was skipped: predecessor Feature") }
        #expect(skipLines == [try #require(NightCardMaintenance.authoringLine(for: latest, journal: journal))])
        #expect(lines.first == skipLines.first)
        #expect(lines.count == 2)
    }
}

extension UnmergedStackGateTests {
    @Test("Native cancellation keeps the local-git stack gate and effective base until an Observed Merge")
    func canceledFeatureRetainsGateUntilMerge() async throws {
        let backend = try await backendWithBranches("stack-canceled", branches: ["yh-f1"])
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let featureID = try await insertLandedFeature(journal, backend, issueID: "F1", branch: "yh-f1")
        let (context, _) = try makeGateContext(journal, repositories: backendRepositories(backend))
        let native = object("F1", state: stateCanceledByCategory, updatedAt: 20)
        let data = try JSONEncoder().encode(native)
        let payload = try #require(String(bytes: data, encoding: .utf8))
        try journal.recordBoardRead(BoardReadRecord(
            issuesSynced: nil, commentsSynced: nil,
            issues: [BoardIssueObservation(issueID: "F1", updatedAt: native.updatedAt, payload: payload)],
            comments: [], leavesBuildPending: false, clearsBuildPending: false, forgetsBefore: .distantFuture
        ), runID: context.runID)
        let gate = PredecessorAncestryGate()
        let blocked = try await gate.check(context, unmergedFeaturesMax: 1)
        #expect(namedUnmerged(blocked) == [NamedUnmerged("F1", ["backend"])])
        #expect(try journal.effectiveBase(repository: "backend")?.featureID == featureID)
        #expect(try journal.landings(featureID: featureID).isEmpty)

        _ = await backend.run(["merge", "--no-ff", "-m", "merge canceled Feature", "yh-f1"])
        let opened = try await gate.check(context, unmergedFeaturesMax: 1)
        #expect(opened == .open)
        #expect(try journal.unmergedFeatureStack().isEmpty)
        #expect(try journal.landings(featureID: featureID).count == 1)
        #expect(try journal.featureBoardObservation(issueID: "F1")?.workflowState == stateCanceledByCategory)
    }
}
