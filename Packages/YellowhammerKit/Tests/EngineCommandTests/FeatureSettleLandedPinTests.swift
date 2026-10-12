import Domain
@testable import Engine
import Foundation
@testable import Journal
import Repositories
import Testing

// feature-authoring/select-the-next-feature, OQ164: abandoning a Feature by the settle gesture deletes the
// refs/yellowhammer/landed/<branch> pins it left in each repository's main clone, and a pin that cannot be
// deleted never fails the abandon.

@Suite("Settle a Feature: landed pins")
struct FeatureSettleLandedPinTests {
    /// Records `commit` as landed for the world's Feature in `repository`, under a throwaway Act lease.
    private func recordLanded(_ world: SettleWorld, repository: String, commit: String) throws {
        let runID = RunID()
        guard case .claimed = try world.journal.claimActLease(act: .land, runID: runID, mode: .real) else {
            throw JournalError.actLeaseLost(runID: runID, holder: nil)
        }
        try world.journal.recordLandedCommit(
            featureID: world.featureID, repository: repository, commit: commit, runID: runID
        )
        try world.journal.releaseActLease(runID: runID)
    }

    private func inFlightFeature(_ world: SettleWorld) throws -> FeatureRecord {
        try #require(try world.journal.inFlightFeature()).feature
    }

    private func landedPinFailures(_ journal: JournalStore) throws -> [JournalEvent] {
        try journal.events(ofType: .landedPinFailed).map(\.event)
    }

    @Test("abandon deletes the landed pin of every repository the Feature pushed, and keeps the record")
    func abandonDeletesThePins() async throws {
        let world = try await makeSettleWorld()
        let backend = TestGitRepo(name: "settle-pin-backend")
        await backend.initRepo()
        let commit = try await backend.commit(message: "feature work")
        let branch = try #require(
            try world.journal.resolvedFeatureBranch(feature: try inFlightFeature(world), repository: "backend")
        )
        let ref = LandedTipPin.ref(for: branch)
        _ = await backend.run(["update-ref", ref, commit])
        try recordLanded(world, repository: "backend", commit: commit)
        await world.seedFeatureIssueState(SettleValue.abandoned.rawValue)
        let repo = Repo(name: "backend", path: backend.path, role: .backend, defaultBranch: "main")
        let context = try world.makeContext(repositories: ProjectRepositories(workingRepos: [repo]))

        try await FeatureSettleGesture().settle(
            feature: try inFlightFeature(world), cycleID: world.cycleID, context: context
        )

        #expect(try settleFeatureRow(world.journal, featureID: world.featureID).abandonedAt != nil)
        #expect(await backend.revParse(ref) == nil)
        #expect(try landedPinFailures(world.journal).isEmpty)
        #expect(try world.journal.landedCommit(featureID: world.featureID, repository: "backend") == commit)
    }

    @Test("a pin that cannot be deleted is reported in the Journal and the abandon still happens")
    func failedUnpinNeverFailsTheAbandon() async throws {
        let world = try await makeSettleWorld()
        // An existing directory that is not a repository: git cannot delete anything in it.
        let notARepo = TestGitRepo(name: "settle-pin-not-a-repo")
        try recordLanded(world, repository: "backend", commit: "abc123")
        await world.seedFeatureIssueState(SettleValue.abandoned.rawValue)
        let repo = Repo(name: "backend", path: notARepo.path, role: .backend, defaultBranch: "main")
        let context = try world.makeContext(repositories: ProjectRepositories(workingRepos: [repo]))

        try await FeatureSettleGesture().settle(
            feature: try inFlightFeature(world), cycleID: world.cycleID, context: context
        )

        #expect(try settleFeatureRow(world.journal, featureID: world.featureID).abandonedAt != nil)
        #expect(try world.journal.events(ofType: .featureReleased).count == 1)
        let failures = try landedPinFailures(world.journal)
        #expect(failures.count == 1)
        guard case .landedPinFailed(let issueID, let repository, _, let commit, let operation, let reason) = failures[0]
        else {
            Issue.record("expected landedPinFailed")
            return
        }
        #expect(issueID == "FEAT-1")
        #expect(repository == "backend")
        #expect(commit == "abc123")
        #expect(operation == .unpin)
        #expect(!reason.isEmpty)
    }

    @Test("a repository whose clone is gone has nothing to unpin, and that is not a failure")
    func missingCloneIsNotAFailure() async throws {
        let world = try await makeSettleWorld()
        try recordLanded(world, repository: "backend", commit: "abc123")
        await world.seedFeatureIssueState(SettleValue.abandoned.rawValue)
        let gone = FileManager.default.temporaryDirectory
            .appending(component: "settle-pin-gone-\(UUID().uuidString)", directoryHint: .isDirectory)
        let repo = Repo(name: "backend", path: gone.path, role: .backend, defaultBranch: "main")
        let context = try world.makeContext(repositories: ProjectRepositories(workingRepos: [repo]))

        try await FeatureSettleGesture().settle(
            feature: try inFlightFeature(world), cycleID: world.cycleID, context: context
        )

        #expect(try settleFeatureRow(world.journal, featureID: world.featureID).abandonedAt != nil)
        #expect(try landedPinFailures(world.journal).isEmpty)
    }
}
