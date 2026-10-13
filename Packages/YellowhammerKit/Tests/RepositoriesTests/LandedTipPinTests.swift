import Domain
import Foundation
import Testing

@testable import Repositories

// The landed-tip pin (feature-authoring/select-the-next-feature, OQ164): `refs/yellowhammer/landed/<branch>`
// in the main clone, against a real temporary repository.

@Suite("Landed tip pin")
struct LandedTipPinTests {
    @Test("the ref is fully qualified, including for a branch name that carries a prefix with a slash")
    func refIsFullyQualified() {
        #expect(LandedTipPin.ref(for: FeatureBranch(name: "yh-p-f")) == "refs/yellowhammer/landed/yh-p-f")
        #expect(
            LandedTipPin.ref(for: FeatureBranch(name: "rozd/yh-p-f")) == "refs/yellowhammer/landed/rozd/yh-p-f"
        )
    }

    @Test("pin writes the ref at the commit, moves it on a second push, and survives deleting the branch")
    func pinWritesAndMoves() async throws {
        let repo = GitFixture(name: "landed-pin-\(UUID().uuidString)")
        await repo.initRepo()
        let first = try await repo.commit(message: "first")
        let branch = FeatureBranch(name: "rozd/yh-p-f")
        _ = await repo.run(["checkout", "-b", branch.name])
        let tip = try await repo.commit(filename: "f.txt", message: "feature")
        let pin = LandedTipPin()

        #expect(await pin.pin(commit: first, branch: branch, repositoryPath: repo.path) == .done)
        #expect(await repo.revParse(LandedTipPin.ref(for: branch)) == first)
        #expect(await pin.pin(commit: tip, branch: branch, repositoryPath: repo.path) == .done)
        #expect(await pin.pinnedCommit(branch: branch, repositoryPath: repo.path) == tip)

        _ = await repo.run(["checkout", "main"])
        _ = await repo.run(["branch", "-D", branch.name])
        #expect(await repo.revParse("refs/heads/\(branch.name)") == nil)
        #expect(await pin.pinnedCommit(branch: branch, repositoryPath: repo.path) == tip)
    }

    @Test("unpin deletes the ref, and an already-absent ref is success")
    func unpinDeletesAndToleratesAbsence() async throws {
        let repo = GitFixture(name: "landed-unpin-\(UUID().uuidString)")
        await repo.initRepo()
        let commit = try await repo.commit(message: "first")
        let branch = FeatureBranch(name: "yh-p-f")
        let pin = LandedTipPin()

        _ = await pin.pin(commit: commit, branch: branch, repositoryPath: repo.path)
        #expect(await pin.unpin(branch: branch, repositoryPath: repo.path) == .done)
        #expect(await repo.revParse(LandedTipPin.ref(for: branch)) == nil)
        #expect(await pin.unpin(branch: branch, repositoryPath: repo.path) == .done)
    }

    @Test("a path that is not a repository fails both ways, with git's reason")
    func notARepository() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(component: "landed-pin-missing-\(UUID().uuidString)", directoryHint: .isDirectory)
        let branch = FeatureBranch(name: "yh-p-f")
        let pin = LandedTipPin()

        guard case .failed(let pinReason) = await pin.pin(
            commit: "abc123", branch: branch, repositoryPath: directory.path
        ) else {
            Issue.record("pin should have failed")
            return
        }
        #expect(!pinReason.isEmpty)
        guard case .failed = await pin.unpin(branch: branch, repositoryPath: directory.path) else {
            Issue.record("unpin should have failed")
            return
        }
    }
}
