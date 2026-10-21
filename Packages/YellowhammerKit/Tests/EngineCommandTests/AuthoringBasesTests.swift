import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Synchronization
import Testing

// roadmap P23.2 (spec: feature-authoring/select-the-next-feature, `#effective-base`): the author Act selects
// against `effective_base(R)` — the pinned landed tip of the most recent Feature in the Unmerged Feature Stack U
// that pushed in R, else mainline — while `context.mainlines` stays the real mainline everywhere else. Real git;
// the fixtures are PredecessorAncestryGateFixtures.swift's.

/// `repo-a` with mainline `M` (origin/main) and Feature F1's branch `yh-f1` one commit ahead at `C1`, which adds
/// `Sources/Contract.swift` — a file that exists only on F1's branch. The branch itself is gone from the clone,
/// as after Orca ADE removed the Worktree; `pin` writes `refs/yellowhammer/landed/yh-f1` at `C1`.
private struct StackedWorld: ~Copyable {
    let repo: GateGitFixture
    let mainline: String
    let tip: String

    static func make(pin: Bool = true, originBranch: Bool = false) async throws -> StackedWorld {
        let repo = GateGitFixture(name: "repo-a")
        await repo.initRepo(defaultBranch: "main")
        let mainline = try await repo.commit(filename: "README.md", content: "mainline", message: "mainline")
        await repo.run(["update-ref", "refs/remotes/origin/main", mainline])
        await repo.run(["checkout", "-b", "yh-f1"])
        try FileManager.default.createDirectory(
            at: repo.url.appending(component: "Sources"), withIntermediateDirectories: true
        )
        let tip = try await repo.commit(
            filename: "Sources/Contract.swift", content: "public protocol Contract {}\n", message: "F1"
        )
        await repo.run(["checkout", "main"])
        await repo.run(["branch", "-D", "yh-f1"])
        if pin { await repo.run(["update-ref", "refs/yellowhammer/landed/yh-f1", tip]) }
        if originBranch { await repo.run(["update-ref", "refs/remotes/origin/yh-f1", tip]) }
        return StackedWorld(repo: repo, mainline: mainline, tip: tip)
    }

    var repositories: ProjectRepositories {
        ProjectRepositories(
            workingRepos: [
                Repo(name: "repo-a", path: repo.path, role: .backend, defaultBranch: "main"),
                Repo(
                    name: "repo-b", path: "/nonexistent/repo-b", role: .backend,
                    consumes: [RepoDependency(producer: "repo-a", via: .mainline)]
                )
            ],
            specSource: SpecSource(path: "/nonexistent/spec")
        )
    }

    /// The real mainline snapshot the Act-start refresh would hand the invocation.
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

/// Seeds F1 in U: archived, verified, pushed in `repo-a` on `yh-f1` at `landedCommit`, no Observed Merge.
@discardableResult
private func seedF1(_ journal: JournalStore, landedCommit: String?) throws -> Int64 {
    try insertGateFeature(
        journal, issueID: "FEAT-1", branch: "yh-f1", repositories: ["repo-a"], landed: true,
        landedCommits: landedCommit.map { ["repo-a": $0] } ?? [:]
    )
}

/// The author Act's context: the gate fixture's lease and Night, with the real mainline snapshot.
private func authorContext(_ journal: JournalStore, world: borrowing StackedWorld) throws -> ActContext {
    let (gate, _) = try makeGateContext(journal, repositories: world.repositories)
    return ActContext(
        act: gate.act, mode: gate.mode, trigger: gate.trigger, runID: gate.runID, journal: journal,
        night: gate.night, mainlines: world.mainlines, repositories: world.repositories
    )
}

@Suite("Authoring bases: effective_base(R) per working Repo")
struct AuthoringBasesTests {
    @Test("A repository F1 pushed in is authored on its pin; every other keeps its mainline")
    func stackedRepositoryReadsThePin() async throws {
        let world = try await StackedWorld.make()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let f1 = try seedF1(journal, landedCommit: world.tip)
        let context = try authorContext(journal, world: world)

        let bases = try await AuthoringBases.fromStack(context: context)

        #expect(bases.faults.isEmpty)
        #expect(bases.mainlines["repo-a"] == ResolvedMainline(
            repository: "repo-a", defaultBranch: "main", ref: "refs/yellowhammer/landed/yh-f1", commit: world.tip
        ))
        #expect(bases.mainlines["repo-b"] == world.mainlines["repo-b"])
        #expect(bases.records == [
            FeatureBaseRecord(
                repository: "repo-a", baseRef: "refs/yellowhammer/landed/yh-f1", baseCommit: world.tip,
                stackedOnFeatureID: f1
            ),
            FeatureBaseRecord(repository: "repo-b", baseRef: "refs/remotes/origin/main", baseCommit: "b0")
        ])
        // The Act's own snapshot is untouched: everything outside selection still reads the real mainline.
        #expect(context.mainlines["repo-a"]?.ref == "refs/remotes/origin/main")
        #expect(context.authoring(against: bases).featureBases == bases.records)
    }

    @Test("With the pin absent, the remote-tracking Feature Branch is the base")
    func pinAbsentFallsBackToTheOriginBranch() async throws {
        let world = try await StackedWorld.make(pin: false, originBranch: true)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try seedF1(journal, landedCommit: world.tip)

        let bases = try await AuthoringBases.fromStack(context: try authorContext(journal, world: world))

        #expect(bases.faults.isEmpty)
        #expect(bases.mainlines["repo-a"]?.commit == world.tip)
    }

    @Test("A pin at a commit other than the recorded one is a fault, never a fallback to mainline")
    func pinMismatchIsAFault() async throws {
        let world = try await StackedWorld.make()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try seedF1(journal, landedCommit: world.mainline)

        let bases = try await AuthoringBases.fromStack(context: try authorContext(journal, world: world))

        #expect(bases.faults == [.commitMismatch(
            repository: "repo-a", branch: "yh-f1", featureIssueID: "FEAT-1", resolved: world.tip,
            recorded: world.mainline
        )])
        #expect(!bases.records.contains { $0.repository == "repo-a" })
    }

    @Test("A base that resolves nowhere is a fault")
    func unresolvableBaseIsAFault() async throws {
        let world = try await StackedWorld.make(pin: false)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try seedF1(journal, landedCommit: world.tip)

        let bases = try await AuthoringBases.fromStack(context: try authorContext(journal, world: world))

        #expect(bases.faults == [.unresolved(repository: "repo-a", branch: "yh-f1", featureIssueID: "FEAT-1")])
    }

    @Test("With U empty, every repository is authored on its mainline")
    func unstackedRepositoryKeepsItsMainline() async throws {
        let world = try await StackedWorld.make()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let context = try authorContext(journal, world: world)

        let bases = try await AuthoringBases.fromStack(context: context)

        #expect(bases.faults.isEmpty)
        #expect(bases.mainlines == context.mainlines)
        #expect(bases.records.map(\.stackedOnFeatureID) == [nil, nil])
    }

    @Test("fromRecord rebuilds the snapshot a Feature was authored against from feature_base")
    func fromRecordRoundTrips() async throws {
        let world = try await StackedWorld.make()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try seedF1(journal, landedCommit: world.tip)
        let context = try authorContext(journal, world: world)
        let stacked = try await AuthoringBases.fromStack(context: context)
        let f2 = try insertGateFeature(
            journal, issueID: "FEAT-2", branch: "yh-f2", repositories: ["repo-a"], inFlight: true
        )
        try journal.recordFeatureBases(featureID: f2, bases: stacked.records)

        let recorded = try AuthoringBases.fromRecord(journal: journal, featureID: f2, context: context)

        #expect(recorded.mainlines == stacked.mainlines)
        #expect(recorded.records == stacked.records)
        #expect(recorded.faults.isEmpty)
    }

    @Test("A contract that exists only on F1's branch transcribes and stays fresh at the stacked base")
    func transcriptionAndReadinessResolveAtTheStackedBase() async throws {
        let world = try await StackedWorld.make()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try seedF1(journal, landedCommit: world.tip)
        let context = try authorContext(journal, world: world)
        let bases = try await AuthoringBases.fromStack(context: context)
        let reader = MainlineReader(refresher: MainlineRefresher())
        let contract = ContractDraft(repository: "repo-a", paths: ["Sources/Contract.swift"])

        let block = try await reader.transcribe(contract, in: world.repositories, mainlines: bases.mainlines)
        #expect(block.mainlineCommit == world.tip)
        #expect(block.content.contains("public protocol Contract"))
        await #expect(throws: (any Error).self) {
            try await reader.transcribe(contract, in: world.repositories, mainlines: context.mainlines)
        }

        // The authoring-time provenance test (`AdoptionRevalidation`) reads the same snapshot.
        let stacked = await ProvenanceDiffTester().evaluate(
            [block], projectRepositories: world.repositories, mainlines: bases.mainlines
        )
        let mainline = await ProvenanceDiffTester().evaluate(
            [block], projectRepositories: world.repositories, mainlines: context.mainlines
        )
        #expect(stacked.isAllClean)
        #expect(!mainline.isAllClean)
    }
}

/// A `PredecessorGate` and a `FeatureAuthoring` that keep the context each was handed.
private final class ContextCapture: PredecessorGate, FeatureAuthoring, Sendable {
    private let state = Mutex<(gate: ActContext?, authoring: ActContext?)>((nil, nil))

    var gate: ActContext? { state.withLock { $0.gate } }
    var authoring: ActContext? { state.withLock { $0.authoring } }

    func check(_ context: ActContext) async throws -> PredecessorGateOutcome {
        state.withLock { $0.gate = context }
        return .landed
    }

    func selectAndAuthor(_ context: ActContext) async throws -> FeatureAuthoringOutcome {
        state.withLock { $0.authoring = context }
        return .authored
    }
}

@Suite("Author Act: selection on effective_base(R), the rest on mainline")
struct AuthorActEffectiveBaseTests {
    @Test("Selection is handed the stacked snapshot; the gate still reads the remote-tracking ref")
    func selectionGetsTheStackedSnapshot() async throws {
        let world = try await StackedWorld.make()
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        let f1 = try seedF1(journal, landedCommit: world.tip)
        let capture = ContextCapture()

        let act = AuthorAct(predecessorGate: capture, authoring: capture)
        try await act.run(try authorContext(journal, world: world))

        let gate = try #require(capture.gate)
        let authoring = try #require(capture.authoring)
        #expect(gate.mainlines["repo-a"]?.ref == "refs/remotes/origin/main")
        #expect(gate.featureBases.isEmpty)
        #expect(authoring.mainlines["repo-a"]?.ref == "refs/yellowhammer/landed/yh-f1")
        #expect(authoring.mainlines["repo-a"]?.commit == world.tip)
        #expect(authoring.featureBases.first?.stackedOnFeatureID == f1)
    }

    @Test("An unresolvable stacked base is an authoring fault: nothing is selected")
    func unresolvableBaseFaultsTheAct() async throws {
        let world = try await StackedWorld.make(pin: false)
        let fixture = try OutboxJournalFixture()
        let journal = try fixture.open()
        try seedF1(journal, landedCommit: world.tip)
        let capture = ContextCapture()

        let act = AuthorAct(predecessorGate: capture, authoring: capture)
        try await act.run(try authorContext(journal, world: world))

        #expect(capture.authoring == nil)
        let failure = try #require(try journal.events(ofType: .featureSelectionFailed).first?.event)
        guard case .featureSelectionFailed(let reason) = failure else {
            Issue.record("expected featureSelectionFailed")
            return
        }
        #expect(reason.contains("repo-a"))
        #expect(reason.contains("refs/yellowhammer/landed/yh-f1"))
    }
}

@Suite("Authoring transaction: the base is recorded at selection")
struct AuthoringTransactionFeatureBaseTests {
    @Test("The accepted plan carries the touched repositories' bases, and finalising records them as feature_base")
    func basesAreRecordedWithTheFeature() async throws {
        let rig = try await AuthoringRig()
        let base = try rig.context()
        let f1 = try insertGateFeature(rig.journal, issueID: "FEAT-0", branch: "yh-f0", repositories: ["backend"])
        let stacked = FeatureBaseRecord(
            repository: "backend", baseRef: "refs/yellowhammer/landed/yh-f0", baseCommit: "c0", stackedOnFeatureID: f1
        )
        let mobile = FeatureBaseRecord(repository: "mobile", baseRef: "refs/remotes/origin/main", baseCommit: "m1")
        let untouched = FeatureBaseRecord(repository: "web", baseRef: "refs/remotes/origin/main", baseCommit: "w1")
        let bases = AuthoringBasesResult(mainlines: base.mainlines, records: [stacked, mobile, untouched], faults: [])

        let outcome = try await rig.run(base.authoring(against: bases))

        #expect(outcome == .authored)
        let accepted = try #require(try rig.journal.events(ofType: .featureAuthoringAccepted).first?.event)
        guard case .featureAuthoringAccepted(let plan) = accepted else {
            Issue.record("expected featureAuthoringAccepted")
            return
        }
        #expect(plan.bases == [stacked, mobile])
        let (feature, _) = try #require(try rig.journal.inFlightFeature())
        #expect(try rig.journal.featureBases(featureID: feature.id) == [stacked, mobile])
    }
}
