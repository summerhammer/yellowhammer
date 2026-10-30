import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// OQ191 item 4 with the Operator's OQ194 decision as built (landing/open-one-pull-request-per-repository
// #remote-tip-check): when one lane's remote Feature Branch is not at its Pushed Tip, that lane opens no pull
// request and keeps its Worktree held, the Cycle stays unlanded, and the other lanes still publish and release in
// the same firing. The failure is reported on the Feature Card and on each Work Card of the lane, once per remote
// state however many firings find it so, and journaled on every firing.

/// Backend's remote is moved to its base right after the push; mobile's is left alone.
private func moveBackendRemoteAfterPush(_ world: OQ191LandWorld) throws {
    let backend = world["backend"]
    try backend.remote.installHook(
        named: "post-receive", script: "#!/bin/sh\ngit update-ref refs/heads/\(landBranch.name) \(backend.base)\n"
    )
}

private func comments(_ world: OQ191LandWorld, on issue: String) async -> [String] {
    await world.env.board.comments.filter { $0.issue.rawValue == issue }.map(\.body)
}

@Suite("Remote tip check: the other lanes still publish (OQ194, as built)", .serialized)
struct RemoteTipOtherLanesTests {
    @Test("a lane whose remote is at another commit keeps its Worktree held while the other lane publishes")
    func otherLanePublishesAndReleases() async throws {
        let world = try await OQ191LandWorld.make(withMobile: true)
        try moveBackendRemoteAfterPush(world)

        _ = await world.fire()

        #expect(await world.publication.opened("backend").isEmpty)
        #expect(await world.publication.opened("mobile").count == 1)
        #expect(world.env.releaseWorktreeStep(repository: "mobile")?.outcome == .completed)
        #expect(world.env.releaseWorktreeStep(repository: "backend")?.outcome == .skipped)
        let backendHeld = try world.env.journal.heldWorktree(featureID: world.feature.id, repository: "backend")
        #expect(backendHeld?.isHeld == true)
        let landed = try world.isCycleLanded
        #expect(!landed)
    }

    @Test("the failure is the open-pull-request step's detail, a Journal event, and a comment on each Card of the lane")
    func failureIsReportedWhereARefusedPushIs() async throws {
        let world = try await OQ191LandWorld.make(withMobile: true)
        let backend = world["backend"]
        try moveBackendRemoteAfterPush(world)

        _ = await world.fire()

        let expected = "Not landed: the remote branch `\(landBranch.name)` in backend is at "
            + "\(oq191Short(backend.base)), not at the Pushed Tip \(oq191Short(backend.tip)). "
            + "No pull request was opened for backend."
        let step = try recordedLandSteps(world.env.journal, .openPullRequest, repository: "backend").last
        #expect(step?.outcome == .failed)
        #expect(step?.detail == expected)
        let events = try world.env.journal.events(ofType: .remoteTipMismatch).map(\.event)
        #expect(
            events == [.remoteTipMismatch(repository: "backend", pushedTip: backend.tip, remoteCommit: backend.base)]
        )
        #expect(await comments(world, on: "FEAT-1").contains(expected))
        #expect(await comments(world, on: "BACK-1").contains(expected))
        #expect(await !comments(world, on: "MOB-1").contains(expected))
    }

    @Test("a firing that finds the same remote state journals it again but comments only once")
    func repeatedFiringCommentsOnce() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        try moveBackendRemoteAfterPush(world)

        _ = await world.fire()
        _ = await world.fire()

        #expect(try world.env.journal.events(ofType: .remoteTipMismatch).count == 2)
        let failures = await comments(world, on: "FEAT-1").filter { $0.hasPrefix("Not landed: the remote branch") }
        #expect(failures.count == 1)
        #expect(await world.publication.calls.isEmpty)
        let landed = try world.isCycleLanded
        #expect(!landed)
    }

    @Test("an unreadable remote is named with git's reason and the retry")
    func unreadableRemoteNamesTheReason() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let backend = world["backend"]
        try backend.remote.installHook(named: "post-receive", script: "#!/bin/sh\nmv \"$(pwd)\" \"$(pwd).gone\"\n")
        let directory = backend.remoteDirectory
        defer { try? FileManager.default.moveItem(atPath: "\(directory).gone", toPath: directory) }

        _ = await world.fire()

        let step = try recordedLandSteps(world.env.journal, .openPullRequest, repository: "backend").last
        let detail = try #require(step?.detail)
        #expect(detail.hasPrefix("Not landed: the remote branch `\(landBranch.name)` in backend could not be read ("))
        #expect(detail.hasSuffix("). The next land firing retries."))
        let events = try world.env.journal.events(ofType: .remoteTipUnreadable).map(\.event)
        #expect(events.count == 1)
    }
}
