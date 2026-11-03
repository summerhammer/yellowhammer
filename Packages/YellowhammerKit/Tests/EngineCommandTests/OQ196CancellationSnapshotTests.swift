import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

// OQ196 item 1 (landing/open-one-pull-request-per-repository#uncommitted-snapshot): before cancellation releases a
// held Worktree it saves the Worktree's uncommitted changes as a snapshot; a snapshot that cannot be written defers
// the whole cancellation. The same rule applies on a Rehearsal Night.
private let snapshotRef = "refs/yellowhammer/snapshot/\(settleFeatureBranch)"

/// A held backend Worktree at the Pushed Tip with a modified tracked file and an untracked file.
private func dirtyHeldBackend(_ world: SettleWorld) async throws -> TestWorktreeEnvironment {
    let env = try await makeGitWorktree()
    let pushedTip = try await commitInWorktree(env.worktreePath, filename: "pushed.txt", message: "pushed")
    try world.journal.recordFeatureBranch(
        featureID: world.featureID, repository: "backend", branch: FeatureBranch(rawValue: settleFeatureBranch)
    )
    try recordPushedTip(world, repository: "backend", commit: pushedTip)
    try world.holdWorktree(repository: "backend", path: env.worktreePath, pushedCommit: pushedTip)
    try "changed".write(toFile: "\(env.worktreePath)/pushed.txt", atomically: true, encoding: .utf8)
    try "fresh".write(toFile: "\(env.worktreePath)/scratch.txt", atomically: true, encoding: .utf8)
    return env
}

@Suite("OQ196 uncommitted snapshot: saved before cancellation releases a Worktree", .serialized)
struct OQ196CancellationSnapshotTests {
    private func notCancelledComments(_ world: SettleWorld) async -> [String] {
        await world.boards.writing.comments
            .filter { $0.issue.rawValue == "FEAT-1" && $0.body.hasPrefix("Not cancelled: ") }
            .map(\.body)
    }

    private func snapshotReports(_ world: SettleWorld) async -> [String] {
        await world.boards.writing.comments
            .filter { $0.issue.rawValue == "FEAT-1" && $0.body.hasPrefix("Not published:") }
            .map(\.body).filter { $0.contains("saved as a snapshot at") }
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("Case 18: a dirty Worktree is snapshotted, reported as cancelled, and released")
    func dirtyWorktreeIsSnapshotted() async throws {
        let world = try await makeSettleWorld()
        let env = try await dirtyHeldBackend(world)
        await world.seedFeatureCancelled()
        let context = try world.makeContext()

        try await FeatureSettleGesture().settle(
            feature: try inFlightFeature(world), cycleID: world.cycleID, context: context
        )

        let commit = try #require(await GitRunner().run(["-C", env.clone.path, "rev-parse", snapshotRef]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
        let events = try world.journal.events(ofType: .uncommittedChangesSnapshotted).map(\.event)
        #expect(events == [.uncommittedChangesSnapshotted(
            cycleID: world.cycleID,
            snapshot: UncommittedChangesSnapshot(
                repository: "backend", ref: snapshotRef, commit: commit, modified: 1, untracked: 1,
                atCancellation: true
            )
        )])
        let reports = await snapshotReports(world)
        #expect(reports.count == 1)
        #expect(reports.first?.contains("before the Feature was cancelled.") == true)
        #expect(world.workspace.removeCalls.contains { $0.id.rawValue == "wt-backend" })
        #expect(try world.journal.heldWorktree(featureID: world.featureID, repository: "backend") == nil)
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("Case 19: a snapshot that cannot be written defers the whole cancellation until it can")
    func snapshotFailureDefersCancellation() async throws {
        let world = try await makeSettleWorld()
        let env = try await dirtyHeldBackend(world)
        _ = await GitRunner().run(["-C", env.clone.path, "update-ref", "\(snapshotRef)/blocker", env.base])
        await world.seedFeatureCancelled()
        let context = try world.makeContext()

        var reason: String?
        do {
            try await FeatureSettleGesture().settle(
                feature: try inFlightFeature(world), cycleID: world.cycleID, context: context
            )
        } catch let fault as CycleArchiveFault {
            reason = fault.reason
        }
        let body = try #require(reason)

        #expect(body.hasPrefix("Not cancelled: the uncommitted changes in the Worktree for `backend` could not be"))
        #expect(await notCancelledComments(world) == [body])
        #expect(world.workspace.removeCalls.isEmpty)
        #expect(try world.journal.inFlightCycleID() == world.cycleID)
        #expect(try world.journal.events(ofType: .uncommittedChangesSnapshotted).isEmpty)

        _ = await GitRunner().run(["-C", env.clone.path, "update-ref", "-d", "\(snapshotRef)/blocker"])
        try await FeatureSettleGesture().settle(
            feature: try inFlightFeature(world), cycleID: world.cycleID, context: context
        )

        #expect(try world.journal.events(ofType: .uncommittedChangesSnapshotted).count == 1)
        #expect(try world.journal.inFlightCycleID() == nil)
        #expect(world.workspace.removeCalls.contains { $0.id.rawValue == "wt-backend" })
    }

    // landing/open-one-pull-request-per-repository#uncommitted-snapshot
    @Test("Case 20: on a Rehearsal Night the snapshot is written identically")
    func rehearsalNightSnapshotsIdentically() async throws {
        let world = try await makeSettleWorld()
        let env = try await dirtyHeldBackend(world)
        await world.seedFeatureCancelled()
        let context = try world.makeContext(mode: .rehearsal)
        try #require(context.mode == .rehearsal)

        try await FeatureSettleGesture().settle(
            feature: try inFlightFeature(world), cycleID: world.cycleID, context: context
        )

        #expect(await GitRunner().run(["-C", env.clone.path, "rev-parse", "--verify", snapshotRef]).isSuccess)
        let events = try world.journal.events(ofType: .uncommittedChangesSnapshotted).map(\.event)
        #expect(events.count == 1)
        #expect(await snapshotReports(world).count == 1)
        #expect(try world.journal.heldWorktree(featureID: world.featureID, repository: "backend") == nil)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
