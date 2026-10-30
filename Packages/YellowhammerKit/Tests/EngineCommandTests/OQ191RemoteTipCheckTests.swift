import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// OQ191 (yellowhammer#708), item 4: before every pull request open — the first land firing right after its own
// push, and every retry — the land Act checks the remote Feature Branch. At the Pushed Tip the pull request
// opens. At another commit, or absent, it does not open, the Cycle stays unlanded and the failure names both
// commits (an absent branch is named absent). A remote that cannot be read is a failed publication, retried on
// the next firing. A bare remote's `post-receive` hook moves, deletes or hides the branch right after the push
// succeeds. Only the affected lane is asserted: that the other lanes still publish is the Operator's OQ194
// decision as built (`RemoteTipOtherLanesTests`). Spec at yellowhammer-spec f33bccf.

/// What a bare remote's `post-receive` hook does to the Feature Branch right after the push.
private enum RemoteAfterPush {
    /// Moved to the repository's base commit: another commit the remote already holds.
    case movedToBase
    case deleted
    case unreadable
}

private func installPostReceive(_ change: RemoteAfterPush, on repository: OQ191Repository) throws {
    let body = switch change {
    case .movedToBase: "git update-ref refs/heads/\(landBranch.name) \(repository.base)"
    case .deleted: "git update-ref -d refs/heads/\(landBranch.name)"
    case .unreadable: "mv \"$(pwd)\" \"$(pwd).gone\""
    }
    try repository.remote.installHook(named: "post-receive", script: "#!/bin/sh\n\(body)\n")
}

/// Moves a bare remote hidden by `.unreadable` back, so the next firing can read it and the fixture can remove it.
private func restoreRemote(_ repository: OQ191Repository) {
    let directory = repository.remoteDirectory
    try? FileManager.default.moveItem(atPath: "\(directory).gone", toPath: directory)
    try? FileManager.default.removeItem(atPath: "\(directory)/hooks/post-receive")
}

/// Given: backend alone; the remote is changed right after the first firing's push. When: land fires once.
private func firstFiring(_ change: RemoteAfterPush) async throws -> OQ191LandWorld {
    let world = try await OQ191LandWorld.make(withMobile: false)
    try installPostReceive(change, on: world["backend"])
    _ = await world.fire()
    try #require(world.env.pushStep(repository: "backend")?.outcome == .completed)
    return world
}

private func openPullRequestOutcome(_ world: OQ191LandWorld) throws -> LandStepOutcome? {
    try recordedLandSteps(world.env.journal, .openPullRequest, repository: "backend").last?.outcome
}

@Suite("OQ191 remote tip check: before every pull request open", .serialized, .tags(.oq191))
struct OQ191RemoteTipCheckTests {
    // landing/stories/open-one-pull-request-per-repository.md#remote-tip-check
    @Test(
        "item 4: characterization: a remote at the Pushed Tip opens the pull request on the first firing",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func remoteAtThePushedTipOpens() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        let backend = world["backend"]

        let firing = await world.fire()

        #expect(firing.error == nil)
        #expect(await world.publication.opened("backend") == [.init(repository: "backend", remoteTip: backend.tip)])
        #expect(try world.isCycleLanded)
    }

    // landing/stories/open-one-pull-request-per-repository.md#remote-tip-check
    @Test(
        "item 4: a remote at another commit right after the push opens no pull request on the first firing",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func remoteAtAnotherCommitOpensNoPullRequest() async throws {
        let world = try await firstFiring(.movedToBase)
        try #require(await world["backend"].remoteTip() == world["backend"].base)

        #expect(await world.publication.calls.isEmpty)
    }

    // landing/stories/open-one-pull-request-per-repository.md#remote-tip-check
    @Test(
        "item 4: a remote at another commit right after the push leaves the Cycle unlanded",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func remoteAtAnotherCommitLeavesTheCycleUnlanded() async throws {
        let world = try await firstFiring(.movedToBase)
        try #require(await world["backend"].remoteTip() == world["backend"].base)

        let landed = try world.isCycleLanded
        #expect(!landed)
    }

    // landing/stories/open-one-pull-request-per-repository.md#remote-tip-check
    @Test(
        "item 4: a remote at another commit is a failure naming the Pushed Tip and the remote commit",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func remoteAtAnotherCommitNamesBothCommits() async throws {
        let world = try await firstFiring(.movedToBase)
        let backend = world["backend"]
        try #require(await backend.remoteTip() == backend.base)

        let failures = try #require(try await world.remoteTipFailures("backend"))
        #expect(failures.contains { $0.contains(oq191Short(backend.tip)) && $0.contains(oq191Short(backend.base)) })
    }

    // landing/stories/open-one-pull-request-per-repository.md#remote-tip-check
    @Test(
        "item 4: an absent remote branch is handled as at another commit, and the failure names it absent",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func absentRemoteBranchIsNamedAbsent() async throws {
        let world = try await firstFiring(.deleted)
        let backend = world["backend"]
        try #require(await backend.remoteTip() == nil)

        #expect(await world.publication.calls.isEmpty)
        let landed = try world.isCycleLanded
        #expect(!landed)
        let failures = try #require(try await world.remoteTipFailures("backend"))
        #expect(failures.contains { $0.contains("absent") && $0.contains(oq191Short(backend.tip)) })
    }

    // landing/stories/open-one-pull-request-per-repository.md#remote-tip-check
    @Test(
        "item 4: an unreadable remote counts as a failed publication and leaves the Cycle unlanded",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func unreadableRemoteIsAFailedPublication() async throws {
        let world = try await firstFiring(.unreadable)
        let backend = world["backend"]
        defer { restoreRemote(backend) }
        try #require(!FileManager.default.fileExists(atPath: backend.remote.path))

        #expect(await world.publication.calls.isEmpty)
        let outcome = try openPullRequestOutcome(world)
        #expect(outcome == .failed)
        let landed = try world.isCycleLanded
        #expect(!landed)
    }

    // landing/stories/open-one-pull-request-per-repository.md#remote-tip-check
    @Test(
        "item 4: after an unreadable remote, the next firing retries and opens the pull request",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func unreadableRemoteIsRetried() async throws {
        let world = try await firstFiring(.unreadable)
        let backend = world["backend"]
        let callsAfterFirst = await world.publication.calls.count
        restoreRemote(backend)
        try #require(await backend.remoteTip() == backend.tip)

        let second = await world.fire()

        #expect(callsAfterFirst == 0)
        #expect(await world.publication.opened("backend") == [.init(repository: "backend", remoteTip: backend.tip)])
        #expect(second.error == nil)
        #expect(try world.isCycleLanded)
    }

    // landing/stories/open-one-pull-request-per-repository.md#remote-tip-check
    @Test(
        "item 4: on a retry, a remote at another commit opens no pull request and names both commits",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func retryWithRemoteAtAnotherCommit() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false, refusingPullRequest: ["backend"])
        let backend = world["backend"]
        _ = await world.fire()
        try #require(await world.publication.opened("backend").isEmpty)
        try #require(try !world.isCycleLanded)
        #expect(await backend.remote.run(["update-ref", "refs/heads/\(landBranch.name)", backend.base]).isSuccess)
        try #require(await backend.remoteTip() == backend.base)

        _ = await world.fire()

        #expect(await world.publication.opened("backend").isEmpty)
        let landed = try world.isCycleLanded
        #expect(!landed)
        let failures = try #require(try await world.remoteTipFailures("backend"))
        #expect(failures.contains { $0.contains(oq191Short(backend.tip)) && $0.contains(oq191Short(backend.base)) })
    }

    // landing/stories/open-one-pull-request-per-repository.md#remote-tip-check
    @Test(
        "item 4: on a retry, an unreadable remote counts as a failed publication; the next firing opens",
        .bug("https://github.com/summerhammer/yellowhammer/issues/708")
    )
    func retryWithUnreadableRemote() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false, refusingPullRequest: ["backend"])
        let backend = world["backend"]
        _ = await world.fire()
        try #require(await world.publication.opened("backend").isEmpty)
        try FileManager.default.moveItem(atPath: backend.remoteDirectory, toPath: "\(backend.remoteDirectory).gone")
        defer { restoreRemote(backend) }

        _ = await world.fire()

        // Since the retry no longer pushes again (A1), only the remote tip check keeps this Cycle unlanded.
        let outcome = try openPullRequestOutcome(world)
        #expect(outcome == .failed)
        let landed = try world.isCycleLanded
        #expect(!landed)
        restoreRemote(backend)
        _ = await world.fire()
        let opened = await world.publication.opened("backend")
        #expect(opened == [.init(repository: "backend", remoteTip: backend.tip)])
        #expect(try world.isCycleLanded)
    }
}
