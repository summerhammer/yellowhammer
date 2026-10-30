import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// OQ191 (yellowhammer#708; verification/verify-a-feature-clause-by-clause, `#judged-checkout`): what the OQ191
// harness leaves to the engine — the fresh checkouts are removed when Verification ends and a stale root is
// pruned first, a touched repository with no held Worktree forces fresh checkouts and sits at
// `<root>/<repository>` (Operator decision for OQ195), and a repository with nothing recorded is never judged.

@Suite("Judged checkouts: removal, OQ195 layout and the missing-commit fault", .serialized, .tags(.oq191))
struct JudgedCheckoutPreparationTests {
    @Test("Fresh checkouts are removed when Verification ends, after a stale root a crashed Act left is pruned")
    func freshCheckoutsAreRemovedAndStaleRootsPruned() async throws {
        let world = try await OQ191LandWorld.make()
        try await OQ191Dirt.untrackedFile.apply(to: world["mobile"])
        let stale = world.checkoutDirectory.url.appending(path: "cycle-999/backend", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let root = JudgedCheckoutPreparation(directory: world.checkoutDirectory.url).root(cycleID: world.cycleID)

        let firing = await world.fire(keepingCheckouts: false)

        #expect(firing.error == nil)
        let rootPath = root.path(percentEncoded: false)
        #expect(firing.verifiedDirectories.mapValues { oq191RelativePath(from: rootPath, to: $0) }
            == ["backend": "backend", "mobile": "mobile"])
        let left = try FileManager.default.contentsOfDirectory(atPath: world.checkoutDirectory.path)
        #expect(left.isEmpty)
    }

    @Test("A touched repository no Work Card names forces fresh checkouts and sits at <root>/<repository> (OQ195)")
    func lanelessRepositoryForcesFreshCheckouts() async throws {
        let world = try await OQ191LandWorld.make()
        let mobile = world["mobile"]
        try world.env.journal.write { db in
            try db.execute(sql: "DELETE FROM clause WHERE issue_id = 'MOB-1'")
            try db.execute(sql: "DELETE FROM card WHERE issue_id = 'MOB-1'")
            try db.execute(
                sql: "UPDATE worktree SET released_at = ? WHERE repository = 'mobile'",
                arguments: [JournalStore.timestamp(landEpoch)]
            )
        }
        try #require(try world.env.journal.heldWorktree(featureID: world.feature.id, repository: "mobile") == nil)

        let firing = await world.fire()

        #expect(firing.error == nil)
        #expect(try world.env.journal.noPushedBranchRepositories(featureID: world.feature.id) == ["mobile"])
        let root = JudgedCheckoutPreparation(directory: world.checkoutDirectory.url).root(cycleID: world.cycleID)
        let directories = firing.verifiedDirectories
        let rootPath = root.path(percentEncoded: false)
        #expect(directories.mapValues { oq191RelativePath(from: rootPath, to: $0) }
            == ["backend": "backend", "mobile": "mobile"])
        #expect(await oq191RevParse(try #require(directories["mobile"])) == mobile.base)
        let judged = try OQ191Probe.judgedCheckouts(world.env.journal, cycleID: world.cycleID)
        #expect(judged == [
            OQ191JudgedCheckout(
                repository: "backend", commit: world["backend"].tip, kind: .freshCheckout, noPushedBranch: false
            ),
            OQ191JudgedCheckout(repository: "mobile", commit: mobile.base, kind: .freshCheckout, noPushedBranch: true)
        ])
    }

    @Test("A repository with no Pushed Tip and no No-Pushed-Branch Outcome faults Verification, recording nothing")
    func noRecordedCommitFaults() async throws {
        let world = try await VerificationWorld()
        try world.addClause(issue: "BACK-1", cid: "c1")
        let dispatch = ScriptedVerifierDispatch([routeOther: .judgeAll()])
        let checkouts = JudgedCheckoutPreparation(directory: FileManager.default.temporaryDirectory.appending(
            component: "yh-unrecorded-\(UUID().uuidString)", directoryHint: .isDirectory
        ))
        let verification = FeatureVerification(
            resolver: verificationResolver(primary: routeOther), dispatch: dispatch,
            citations: FakeCitationResolver(), checkouts: checkouts
        )

        await #expect {
            _ = try await verification.verify(world.featureContext)
        } throws: { error in
            (error as? VerificationFault)?.reason.contains("\"backend\" has no recorded commit to judge") == true
        }
        #expect(dispatch.requests.isEmpty)
        #expect(try world.journal.featureVerification(cycleID: world.cycleID) == nil)
    }

    @Test("The fresh layout keeps the held Worktrees' relative paths and moves a lane-less name that is taken")
    func layoutKeepsRelativePaths() {
        let layout = FreshCheckoutLayout.relativePaths(
            heldWorktrees: ["api": "/orca/feat/server/api", "web": "/orca/feat/web/"],
            repositories: ["api", "server", "web"]
        )

        #expect(layout == ["api": "server/api", "web": "web", "server": "server-2"])
        #expect(FreshCheckoutLayout.relativePaths(heldWorktrees: ["api": "/orca/feat/api"], repositories: ["api"])
            == ["api": "api"])
    }
}
