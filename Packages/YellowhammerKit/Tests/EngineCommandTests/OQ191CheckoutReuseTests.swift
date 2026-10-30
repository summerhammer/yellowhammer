import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// OQ191 (yellowhammer#708), checkout reuse: held Worktrees are the verifier's checkout only when every touched
// repository's held Worktree has HEAD at its recorded commit and `git status` reports nothing (ignored files
// allowed); otherwise every repository gets a fresh checkout in a new location with the same relative layout.
// Spec at yellowhammer-spec f33bccf. Red cases are known issues until their behaviour lands.

/// How one held Worktree is made not exact and clean before Verification.
enum OQ191Dirt: String, CaseIterable, CustomTestStringConvertible {
    case untrackedFile
    case modifiedFile
    case otherHead

    var testDescription: String { rawValue }

    func apply(to repository: OQ191Repository) async throws {
        switch self {
        case .untrackedFile:
            try "scratch".write(toFile: "\(repository.worktree)/untracked.txt", atomically: true, encoding: .utf8)
        case .modifiedFile:
            try "edited".write(
                toFile: "\(repository.worktree)/\(repository.name)-work.txt", atomically: true, encoding: .utf8
            )
        case .otherHead:
            _ = await oq191Git(repository.worktree, ["checkout", "--quiet", "--detach", repository.base])
        }
    }
}

/// The world with an ignored build directory in every held Worktree, which `git status` does not report.
private func worldWithIgnoredFiles() async throws -> OQ191LandWorld {
    let world = try await OQ191LandWorld.make()
    for repository in world.repositories {
        try "build/\n".write(toFile: "\(repository.clone.path)/.git/info/exclude", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            atPath: "\(repository.worktree)/build", withIntermediateDirectories: true
        )
        try "output".write(toFile: "\(repository.worktree)/build/output.o", atomically: true, encoding: .utf8)
        try #require(await oq191Git(repository.worktree, ["status", "--porcelain"]).stdout.isEmpty)
        try #require(await oq191RevParse(repository.worktree) == repository.tip)
    }
    return world
}

@Suite("OQ191 checkout reuse: all held Worktrees or none", .serialized, .tags(.oq191))
struct OQ191CheckoutReuseTests {
    // verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout
    @Test(
        "items 7, 8: characterization: exact and clean held Worktrees, with ignored files, are the verifier's checkout",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func exactAndCleanWorktreesAreReused() async throws {
        let world = try await worldWithIgnoredFiles()

        let firing = await world.fire()

        #expect(firing.error == nil)
        let held = ["backend": world["backend"].worktree, "mobile": world["mobile"].worktree]
        #expect(firing.verifiedDirectories == held)
    }

    // verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout
    @Test(
        "item 7: the record names held Worktree as the checkout kind of every repository",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func reusedWorktreesAreRecordedHeld() async throws {
        let world = try await worldWithIgnoredFiles()
        let firing = await world.fire()
        try #require(firing.error == nil)
        let expected = world.repositories.map {
            OQ191JudgedCheckout(repository: $0.name, commit: $0.tip, kind: .heldWorktree, noPushedBranch: false)
        }

        let judged = try OQ191Probe.judgedCheckouts(world.env.journal, cycleID: world.cycleID)
        #expect(judged == expected)
    }

    // verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout
    @Test(
        "item 8: one held Worktree that is not exact and clean gives every repository a fresh checkout",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708"),
        arguments: OQ191Dirt.allCases
    )
    func oneDirtyWorktreeGivesEveryRepositoryAFreshCheckout(dirt: OQ191Dirt) async throws {
        let world = try await OQ191LandWorld.make()
        let (backend, mobile) = (world["backend"], world["mobile"])
        try await dirt.apply(to: mobile)
        let mobileStatus = await oq191Git(mobile.worktree, ["status", "--porcelain"]).stdout
        let mobileHead = await oq191RevParse(mobile.worktree)
        try #require(!mobileStatus.isEmpty || mobileHead != mobile.tip)

        let firing = await world.fire()
        try #require(firing.error == nil)
        let directories = firing.verifiedDirectories
        let heldLayout = oq191RelativePath(from: backend.worktree, to: mobile.worktree)

        for repository in world.repositories {
            let directory = try #require(directories[repository.name])
            #expect(oq191Resolved(directory) != oq191Resolved(repository.worktree))
            #expect(await oq191RevParse(directory) == repository.tip)
            #expect(await oq191Git(directory, ["status", "--porcelain"]).stdout.isEmpty)
        }
        let freshBackend = try #require(directories["backend"])
        let freshMobile = try #require(directories["mobile"])
        #expect(oq191RelativePath(from: freshBackend, to: freshMobile) == heldLayout)
    }

    // verification/stories/verify-a-feature-clause-by-clause.md#judged-checkout
    @Test(
        "item 7: a fresh checkout is recorded as the checkout kind of every repository",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func freshCheckoutsAreRecordedFresh() async throws {
        let world = try await OQ191LandWorld.make()
        try await OQ191Dirt.untrackedFile.apply(to: world["mobile"])
        let firing = await world.fire()
        try #require(firing.error == nil)
        let expected = world.repositories.map {
            OQ191JudgedCheckout(repository: $0.name, commit: $0.tip, kind: .freshCheckout, noPushedBranch: false)
        }

        let judged = try OQ191Probe.judgedCheckouts(world.env.journal, cycleID: world.cycleID)
        #expect(judged == expected)
    }
}
