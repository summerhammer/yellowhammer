import Domain
import Foundation
@testable import Repositories
import Testing

// Repositories layer unit tests for UnpublishedHeadPin.pinFeatureBranch (Pin Failure Ruling item 2).
// Tests every outcome: pinned, alreadyPinned, notNeeded, absent, failed.

@Suite("UnpublishedHeadPin: Feature Branch in main clone")
struct UnpublishedBranchPinTests {
    private let branch = FeatureBranch(name: "yh-feature")

    private struct TestWorld: ~Copyable {
        let repo: GitFixture
        let base: String

        static func make() async throws -> TestWorld {
            let repo = GitFixture(name: "branch-pin-\(UUID().uuidString)")
            await repo.initRepo()
            let base = try await repo.commit(filename: "README.md", message: "initial")
            return TestWorld(repo: repo, base: base)
        }
    }

    @Test("pinned: branch is a descendant of recorded commit (relation is after)")
    func pinnedDescendant() async throws {
        let world = try await TestWorld.make()
        _ = await world.repo.run(["checkout", "-b", branch.name])
        let tip = try await world.repo.commit(filename: "feature.txt", message: "feature commit")

        let pin = UnpublishedHeadPin(git: world.repo.git)
        let result = await pin.pinFeatureBranch(
            repositoryPath: world.repo.path, recordedCommit: world.base, branch: branch
        )

        let expectedRef = UnpublishedHeadPin.ref(for: branch)
        guard case .pinned(let ref, let relation) = result else {
            Issue.record("Expected .pinned, got \(result)")
            return
        }
        #expect(ref == expectedRef)
        #expect(relation == .after(commits: 1, head: tip))
        #expect(await world.repo.revParse(expectedRef) == tip)
    }

    @Test("pinned: branch differs from recorded commit (rewritten branch)")
    func pinnedDiffers() async throws {
        let world = try await TestWorld.make()
        // Create an unrelated commit for branch
        _ = await world.repo.run(["checkout", "--orphan", branch.name])
        _ = await world.repo.run(["rm", "-rf", "."])
        let orphanCommit = try await world.repo.commit(filename: "orphan.txt", message: "orphan commit")

        let pin = UnpublishedHeadPin(git: world.repo.git)
        let result = await pin.pinFeatureBranch(
            repositoryPath: world.repo.path, recordedCommit: world.base, branch: branch
        )

        let expectedRef = UnpublishedHeadPin.ref(for: branch)
        guard case .pinned(let ref, let relation) = result else {
            Issue.record("Expected .pinned, got \(result)")
            return
        }
        #expect(ref == expectedRef)
        #expect(relation == .differs(head: orphanCommit))
        #expect(await world.repo.revParse(expectedRef) == orphanCommit)
    }

    @Test("alreadyPinned: ref already points at branch commit; writes nothing")
    func alreadyPinnedOutcome() async throws {
        let world = try await TestWorld.make()
        _ = await world.repo.run(["checkout", "-b", branch.name])
        let tip = try await world.repo.commit(filename: "feature.txt", message: "feature commit")

        let pin = UnpublishedHeadPin(git: world.repo.git)
        let first = await pin.pinFeatureBranch(
            repositoryPath: world.repo.path, recordedCommit: world.base, branch: branch
        )
        let expectedRef = UnpublishedHeadPin.ref(for: branch)
        #expect(first == .pinned(ref: expectedRef, relation: .after(commits: 1, head: tip)))

        let second = await pin.pinFeatureBranch(
            repositoryPath: world.repo.path, recordedCommit: world.base, branch: branch
        )
        #expect(second == .alreadyPinned(ref: expectedRef))
    }

    @Test("notNeeded: branch is at the recorded commit")
    func notNeededWhenAtRecordedCommit() async throws {
        let world = try await TestWorld.make()
        _ = await world.repo.run(["branch", branch.name])

        let pin = UnpublishedHeadPin(git: world.repo.git)
        let result = await pin.pinFeatureBranch(
            repositoryPath: world.repo.path, recordedCommit: world.base, branch: branch
        )

        #expect(result == .notNeeded)
        let expectedRef = UnpublishedHeadPin.ref(for: branch)
        #expect(await world.repo.revParse(expectedRef) == nil)
    }

    @Test("absent: branch does not exist in the repository")
    func absentWhenBranchDoesNotExist() async throws {
        let world = try await TestWorld.make()

        let pin = UnpublishedHeadPin(git: world.repo.git)
        let result = await pin.pinFeatureBranch(
            repositoryPath: world.repo.path, recordedCommit: world.base, branch: branch
        )

        #expect(result == .absent)
    }

    @Test("failed: repositoryPath is not a git repository")
    func failedWhenPathNotGitRepository() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "not-a-repo-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pin = UnpublishedHeadPin()
        let result = await pin.pinFeatureBranch(
            repositoryPath: dir.path(percentEncoded: false), recordedCommit: "abc1234", branch: branch
        )

        guard case .failed = result else {
            Issue.record("Expected .failed, got \(result)")
            return
        }
    }

    @Test("failed: git update-ref is refused")
    func failedWhenRefUpdateRefused() async throws {
        let world = try await TestWorld.make()
        _ = await world.repo.run(["checkout", "-b", branch.name])
        _ = try await world.repo.commit(filename: "feature.txt", message: "feature commit")

        // Block git from creating ref under refs/yellowhammer/unpublished
        let blockerURL = world.repo.url.appending(
            component: ".git/refs/yellowhammer/unpublished", directoryHint: .notDirectory
        )
        try FileManager.default.createDirectory(
            at: blockerURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "blocker".write(to: blockerURL, atomically: true, encoding: .utf8)

        let pin = UnpublishedHeadPin(git: world.repo.git)
        let result = await pin.pinFeatureBranch(
            repositoryPath: world.repo.path, recordedCommit: world.base, branch: branch
        )

        guard case .failed = result else {
            Issue.record("Expected .failed, got \(result)")
            return
        }
    }
}
