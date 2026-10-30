import Domain
import Foundation
import Repositories
import Testing

// feature-authoring/select-the-next-feature, the Observed Merge record (OQ190 item 26): for ancestry, the landing
// commit is the oldest commit on mainline's first-parent chain that contains the tip. Real git, local only.

@Suite("Ancestry tester: landing commit")
struct AncestryLandingCommitTests {
    private func test(_ fixture: borrowing GitFixture, branch: String = "yh-feature") async -> RepoAncestryResult {
        let repo = Repo(name: "app", path: fixture.path, role: .backend)
        return await AncestryTester().testAncestry(branch: branch, in: repo)
    }

    @Test("A merge commit is the landing commit, not a later mainline commit")
    func mergeCommitIsTheLandingCommit() async throws {
        let fixture = GitFixture(name: "landing-merge-\(UUID().uuidString)")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(filename: "init.txt", message: "init")
        _ = await fixture.run(["checkout", "-b", "yh-feature"])
        let tip = try await fixture.commit(filename: "feat.txt", message: "feature")
        _ = await fixture.run(["checkout", "main"])
        _ = try await fixture.commit(filename: "before.txt", message: "mainline before the merge")
        _ = await fixture.run(["merge", "--no-ff", "-m", "merge yh-feature", "yh-feature"])
        let merge = await fixture.revParse("main")
        _ = try await fixture.commit(filename: "after.txt", message: "mainline after the merge")

        let result = await test(fixture)

        #expect(result.isAncestor)
        #expect(result.branchCommit == tip)
        #expect(result.landingCommit == merge)
    }

    @Test("After a fast-forward the tip itself is the landing commit")
    func fastForwardLandsAtTheTip() async throws {
        let fixture = GitFixture(name: "landing-ff-\(UUID().uuidString)")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(filename: "init.txt", message: "init")
        _ = await fixture.run(["checkout", "-b", "yh-feature"])
        _ = try await fixture.commit(filename: "one.txt", message: "first")
        let tip = try await fixture.commit(filename: "two.txt", message: "second")
        _ = await fixture.run(["checkout", "main"])
        _ = await fixture.run(["merge", "--ff-only", "yh-feature"])
        _ = try await fixture.commit(filename: "after.txt", message: "mainline after the fast-forward")

        let result = await test(fixture)

        #expect(result.landingCommit == tip)
    }

    @Test("A tip that is mainline's head is its own landing commit")
    func tipAtTheHeadLandsAtItself() async throws {
        let fixture = GitFixture(name: "landing-head-\(UUID().uuidString)")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(filename: "init.txt", message: "init")
        _ = await fixture.run(["checkout", "-b", "yh-feature"])
        let tip = try await fixture.commit(filename: "feat.txt", message: "feature")
        _ = await fixture.run(["checkout", "main"])
        _ = await fixture.run(["merge", "--ff-only", "yh-feature"])

        let result = await test(fixture)

        #expect(result.landingCommit == tip)
    }

    @Test("A tip merged into another branch lands where that branch was merged into mainline")
    func tipThroughALaterMergeLandsAtThatMerge() async throws {
        let fixture = GitFixture(name: "landing-later-merge-\(UUID().uuidString)")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(filename: "init.txt", message: "init")
        _ = await fixture.run(["checkout", "-b", "yh-feature"])
        let tip = try await fixture.commit(filename: "feat.txt", message: "feature")
        _ = await fixture.run(["checkout", "main"])
        _ = await fixture.run(["checkout", "-b", "yh-lower"])
        _ = try await fixture.commit(filename: "lower.txt", message: "lower")
        // The pull request was merged into the lower branch first, with a merge commit.
        _ = await fixture.run(["merge", "--no-ff", "-m", "merge yh-feature into yh-lower", "yh-feature"])
        _ = await fixture.run(["checkout", "main"])
        _ = try await fixture.commit(filename: "between.txt", message: "mainline before the lower merge")
        _ = await fixture.run(["merge", "--no-ff", "-m", "merge yh-lower", "yh-lower"])
        let lowerMerge = await fixture.revParse("main")
        _ = try await fixture.commit(filename: "after.txt", message: "mainline after")

        let result = await test(fixture)

        #expect(result.isAncestor)
        #expect(result.branchCommit == tip)
        #expect(result.landingCommit == lowerMerge)
    }

    @Test("A tip that is not an ancestor has no landing commit")
    func notAnAncestorHasNoLandingCommit() async throws {
        let fixture = GitFixture(name: "landing-none-\(UUID().uuidString)")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(filename: "init.txt", message: "init")
        _ = await fixture.run(["checkout", "-b", "yh-feature"])
        _ = try await fixture.commit(filename: "feat.txt", message: "feature")
        _ = await fixture.run(["checkout", "main"])
        _ = try await fixture.commit(filename: "other.txt", message: "other")

        let result = await test(fixture)

        #expect(!result.isAncestor)
        #expect(result.landingCommit == nil)
    }
}
