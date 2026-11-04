import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

// Issue #731; spec feature-authoring/select-the-next-feature `#effective-base`: a working repository the in-flight
// Feature does not touch has no `feature_base` row, yet a Card may transcribe a contract from it at the pin of the
// Unmerged Feature Stack's predecessor. Dispatch reads such a repository at its current effective base, not at the
// real mainline, so the predecessor's own change is not a Divergence. Real git throughout.

/// `repo-a` with mainline `M` (origin/main) and the predecessor's Pushed Tip `T`, which adds `Sources/Contract.swift`,
/// pinned under `refs/yellowhammer/landed/yh-pred`. The in-flight Feature touches only `repo-b`.
private struct UntouchedWorld: ~Copyable {
    let repo: GateGitFixture
    let mainline: String
    let tip: String

    static func make(pin: Bool = true) async throws -> UntouchedWorld {
        let repo = GateGitFixture(name: "untouched-a")
        await repo.initRepo(defaultBranch: "main")
        let mainline = try await repo.commit(filename: "README.md", content: "mainline", message: "mainline")
        await repo.run(["update-ref", "refs/remotes/origin/main", mainline])
        try FileManager.default.createDirectory(
            at: repo.url.appending(component: "Sources"), withIntermediateDirectories: true
        )
        let tip = try await repo.commit(
            filename: "Sources/Contract.swift", content: "public protocol Contract {}\n", message: "pred"
        )
        if pin { await repo.run(["update-ref", "refs/yellowhammer/landed/yh-pred", tip]) }
        await repo.run(["reset", "--hard", mainline])
        return UntouchedWorld(repo: repo, mainline: mainline, tip: tip)
    }

    var repositories: ProjectRepositories {
        ProjectRepositories(workingRepos: [
            Repo(name: "repo-a", path: repo.path, role: .backend, defaultBranch: "main"),
            Repo(name: "repo-b", path: "/nonexistent/repo-b", role: .backend)
        ])
    }

    /// The Readiness scenario's `backend` plus `repo-a`.
    var backendRepositories: ProjectRepositories {
        ProjectRepositories(workingRepos: [
            Repo(name: "backend", path: "/nonexistent/backend", role: .backend),
            Repo(name: "repo-a", path: repo.path, role: .backend, defaultBranch: "main")
        ])
    }

    var backendMainlines: ResolvedMainlines {
        ResolvedMainlines(workingRepos: [
            "backend": ResolvedMainline(
                repository: "backend", defaultBranch: "main", ref: "refs/remotes/origin/main", commit: "b0"
            ),
            "repo-a": mainlines["repo-a"]!
        ])
    }

    var mainlines: ResolvedMainlines {
        ResolvedMainlines(workingRepos: [
            "repo-a": ResolvedMainline(
                repository: "repo-a", defaultBranch: "main", ref: "refs/remotes/origin/main", commit: mainline
            ),
            "repo-b": ResolvedMainline(
                repository: "repo-b", defaultBranch: "main", ref: "refs/remotes/origin/main", commit: "b0"
            )
        ])
    }
}

private let repoBRecord = FeatureBaseRecord(repository: "repo-b", baseRef: "refs/remotes/origin/main", baseCommit: "b0")

@Suite("Authoring bases: dispatch reads an untouched repository at its current effective base")
struct UntouchedRepositoryBasesTests {
    @Test("A predecessor in U pushed in an untouched repository: it reads the pin, with no feature_base row added")
    func untouchedRepositoryReadsThePin() async throws {
        let world = try await UntouchedWorld.make()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try insertGateFeature(
            journal, issueID: "FEAT-PRED", branch: "yh-pred", repositories: ["repo-a"], landed: true,
            pushedTips: ["repo-a": world.tip]
        )
        let current = try insertGateFeature(
            journal, issueID: "FEAT-CUR", branch: "yh-cur", repositories: ["repo-b"], inFlight: true
        )
        try journal.recordFeatureBases(featureID: current, bases: [repoBRecord])
        let (gate, _) = try makeGateContext(journal, repositories: world.repositories)
        let context = ActContext(
            act: gate.act, mode: gate.mode, trigger: gate.trigger, runID: gate.runID, journal: journal,
            night: gate.night, mainlines: world.mainlines, repositories: world.repositories
        )

        let recorded = try await AuthoringBases.fromRecord(journal: journal, featureID: current, context: context)

        #expect(recorded.faults.isEmpty)
        #expect(recorded.mainlines["repo-a"] == ResolvedMainline(
            repository: "repo-a", defaultBranch: "main", ref: "refs/yellowhammer/landed/yh-pred", commit: world.tip
        ))
        #expect(recorded.mainlines["repo-b"]?.commit == "b0")
        #expect(recorded.records == [repoBRecord])
    }

    @Test("A predecessor that left U no longer moves an untouched repository off its real mainline")
    func untouchedRepositoryAfterThePredecessorLeftU() async throws {
        let world = try await UntouchedWorld.make()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try insertGateFeature(
            journal, issueID: "FEAT-PRED", branch: "yh-pred", repositories: ["repo-a"], landed: true, released: true,
            pushedTips: ["repo-a": world.tip]
        )
        let current = try insertGateFeature(
            journal, issueID: "FEAT-CUR", branch: "yh-cur", repositories: ["repo-b"], inFlight: true
        )
        try journal.recordFeatureBases(featureID: current, bases: [repoBRecord])
        let (gate, _) = try makeGateContext(journal, repositories: world.repositories)
        let context = ActContext(
            act: gate.act, mode: gate.mode, trigger: gate.trigger, runID: gate.runID, journal: journal,
            night: gate.night, mainlines: world.mainlines, repositories: world.repositories
        )

        let recorded = try await AuthoringBases.fromRecord(journal: journal, featureID: current, context: context)

        #expect(recorded.faults.isEmpty)
        #expect(recorded.mainlines["repo-a"] == world.mainlines["repo-a"])
        #expect(recorded.records == [repoBRecord])
    }

    @Test("An untouched repository whose stacked base resolves nowhere is a fault, never the real mainline")
    func unresolvableUntouchedBaseIsAFault() async throws {
        let world = try await UntouchedWorld.make(pin: false)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try insertGateFeature(
            journal, issueID: "FEAT-PRED", branch: "yh-pred", repositories: ["repo-a"], landed: true,
            pushedTips: ["repo-a": world.tip]
        )
        let current = try insertGateFeature(
            journal, issueID: "FEAT-CUR", branch: "yh-cur", repositories: ["repo-b"], inFlight: true
        )
        try journal.recordFeatureBases(featureID: current, bases: [repoBRecord])
        let (gate, _) = try makeGateContext(journal, repositories: world.repositories)
        let context = ActContext(
            act: gate.act, mode: gate.mode, trigger: gate.trigger, runID: gate.runID, journal: journal,
            night: gate.night, mainlines: world.mainlines, repositories: world.repositories
        )

        let recorded = try await AuthoringBases.fromRecord(journal: journal, featureID: current, context: context)

        #expect(recorded.faults == [.unresolved(repository: "repo-a", branch: "yh-pred", featureIssueID: "FEAT-PRED")])
    }
}

@Suite("Readiness Check: a Transcription Block of an untouched repository at the predecessor's pin")
struct UntouchedRepositoryReadinessTests {
    @Test("Not a Divergence at the dispatch bases; the repro against the real mainline is one")
    func pinnedTranscriptionIsNotADivergence() async throws {
        let world = try await UntouchedWorld.make()
        let scenario = try await makeReadinessScenario()
        defer { cleanup(scenario) }
        let journal = scenario.journal
        let runID = RunID()
        guard case .claimed = try journal.claimActLease(act: .build, runID: runID, mode: .rehearsal) else {
            throw JournalError.actLeaseLost(runID: runID, holder: nil)
        }
        defer { _ = try? journal.releaseActLease(runID: runID) }
        let opened = try journal.openNight(nightStart: readinessNightStart, mode: .rehearsal, act: .build, runID: runID)
        let (feature, cycleID) = try #require(try journal.inFlightFeature())
        try insertGateFeature(
            journal, issueID: "FEAT-PRED", branch: "yh-pred", repositories: ["repo-a"], landed: true,
            pushedTips: ["repo-a": world.tip]
        )
        try journal.recordFeatureBases(featureID: feature.id, bases: [
            FeatureBaseRecord(repository: "backend", baseRef: "refs/remotes/origin/main", baseCommit: "b0")
        ])
        let content = "public protocol Contract {}\n"
        try journal.recordTranscriptionBlocks(cardID: scenario.cardTwo, [TranscriptionBlock(
            repository: "repo-a", paths: ["Sources/Contract.swift"], mainlineCommit: world.tip, content: content,
            contentHash: ManagedBlockFence.sha256(content), authorSupplied: false
        )])

        let act = ActContext(
            act: .build, mode: .rehearsal, trigger: .scheduled, runID: runID, journal: journal, night: opened.night,
            mainlines: world.backendMainlines, repositories: world.backendRepositories
        )
        let readiness = ReadinessCheck(provenance: ProvenanceDiffTester(), citations: FakeCitationResolver())
        let card = try journal.card(id: scenario.cardTwo)

        let dispatching = try await BuildActContext.dispatching(
            feature: feature, cycleID: cycleID, reconciliation: WorktreeReconciliation(), deltaRead: nil, act: act
        )
        guard case .ready = try await readiness.evaluate(card: card, context: dispatching) else {
            Issue.record("expected an untouched repository at the predecessor's pin to read Ready")
            return
        }

        let repro = BuildActContext(
            act: act, feature: feature, cycleID: cycleID, reconciliation: WorktreeReconciliation(), deltaRead: nil,
            recordedBaseMainlines: act.mainlines
        )
        guard case .diverged(let finding) = try await readiness.evaluate(card: card, context: repro) else {
            Issue.record("expected the real-mainline read to reproduce the Divergence")
            return
        }
        #expect(finding.repository == "repo-a")
        #expect(finding.changedPaths == ["Sources/Contract.swift"])
    }
}
