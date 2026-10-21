import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
import Journal
import Repositories
import Testing

// roadmap P23.3; spec feature-authoring/select-the-next-feature `#effective-base`: the Brief and the Readiness Check
// were resolved against the recorded base, so the dispatch-time check resolves a Card's citations there too — not
// against the real mainline, which can still be behind the stack.

/// Resolves a citation iff `stacked.txt` exists at the mainline pin the Readiness Check hands it for `backend`,
/// reading real git in a fixture repository.
private struct FileAtMainlineResolver: CitationResolving {
    func resolve(
        _ citation: SpecCitation, in projectRepositories: ProjectRepositories, mainlines: ResolvedMainlines
    ) async -> SpecCitationResolution {
        guard let repo = projectRepositories.workingRepo(named: "backend") else {
            return .unresolved(citation: citation, reason: "no backend")
        }
        do {
            let read = try await MainlineReader().readFile(
                path: "stacked.txt", in: repo, mainline: mainlines["backend"]
            )
            return .resolved(
                citation: citation, resolvedPath: "stacked.txt", commit: read.commit, repository: "backend"
            )
        } catch {
            return .unresolved(citation: citation, reason: "\(error)")
        }
    }
}

@Suite("Readiness Check: dispatch against the Feature's recorded base")
struct RecordedBaseReadinessTests {
    /// Commit A on main, commit B (adds `stacked.txt`) pinned under `refs/yellowhammer/landed`; `origin/main`
    /// stays at A, as it does while the stack's tip is only on the landed pin.
    private static func seedStack(in fixture: borrowing EngineGitFixture) async throws -> [String] {
        await fixture.initRepo()
        let commitA = try await fixture.commit(filename: "a.txt", content: "a")
        let commitB = try await fixture.commit(filename: "stacked.txt", content: "b")
        await fixture.run(["update-ref", "refs/remotes/origin/main", commitA])
        await fixture.run(["update-ref", "refs/yellowhammer/landed/team/b1", commitB])
        await fixture.run(["checkout", "--detach", commitA])
        return [commitA, commitB]
    }

    @Test("A file that exists only at the recorded base resolves at dispatch; against real mainline it does not")
    func resolvesAgainstTheRecordedBase() async throws {
        let fixture = EngineGitFixture(name: "recorded-base-readiness")
        let commits = try await Self.seedStack(in: fixture)
        let (commitA, commitB) = (commits[0], commits[1])
        let backend = Repo(name: "backend", path: fixture.path, role: .backend)
        let repositories = ProjectRepositories(workingRepos: [backend])

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
        let predecessor = try insertReconcilerFeature(journal, issueID: "FEAT-PRED")
        try journal.recordFeatureBases(featureID: feature.id, bases: [FeatureBaseRecord(
            repository: "backend", baseRef: "refs/yellowhammer/landed/team/b1", baseCommit: commitB,
            stackedOnFeatureID: predecessor
        )])

        let realMainline = ResolvedMainline(
            repository: "backend", defaultBranch: "main", ref: "refs/remotes/origin/main", commit: commitA
        )
        let mainlines = ResolvedMainlines(workingRepos: ["backend": realMainline])
        let act = ActContext(
            act: .build, mode: .rehearsal, trigger: .scheduled, runID: runID, journal: journal, night: opened.night,
            mainlines: mainlines, repositories: repositories
        )
        let recorded = try AuthoringBases.fromRecord(journal: journal, featureID: feature.id, context: act)
        let readiness = ReadinessCheck(provenance: FakeProvenanceTester(), citations: FileAtMainlineResolver())

        let atRecordedBase = BuildActContext(
            act: act, feature: feature, cycleID: cycleID, reconciliation: WorktreeReconciliation(), deltaRead: nil,
            recordedBaseMainlines: act.authoring(against: recorded).mainlines
        )
        let card = try journal.card(id: scenario.cardTwo)
        guard case .ready(let ready) = try await readiness.evaluate(card: card, context: atRecordedBase) else {
            Issue.record("expected the citation to resolve at the recorded base")
            return
        }
        #expect(ready.specCommit == commitB)

        // Without the recorded base the same Act reads the real mainline and cannot see the file.
        let atMainline = BuildActContext(
            act: act, feature: feature, cycleID: cycleID, reconciliation: WorktreeReconciliation(), deltaRead: nil,
            recordedBaseMainlines: act.mainlines
        )
        guard case .notReady = try await readiness.evaluate(card: card, context: atMainline) else {
            Issue.record("expected the citation not to resolve at real mainline")
            return
        }
        #expect(act.mainlines["backend"]?.commit == commitA)
    }
}
