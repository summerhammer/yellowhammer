import Domain
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

// feature-authoring/select-the-next-feature, OQ164: Project removal abandons the in-flight Feature, so it
// deletes that Feature's refs/yellowhammer/landed/<branch> pins too — after the Journal write, and never
// failing the removal.

@Test("Removal deletes the abandoned Feature's landed pin, after the Journal write")
func removalDeletesTheLandedPin() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    let repo = TestGitRepo(name: "removal-landed-pin")
    await repo.initRepo()
    let commit = try await repo.commit()
    _ = await repo.run(["checkout", "-b", removalBranch.name])
    try directory.writeValidProjectFile(id: "alpha", repoPath: repo.path)
    let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)

    let journal = try JournalStore.openSeeded(
        configurationDirectory: directory.url, projectID: try #require(ProjectID(rawValue: "alpha"))
    )
    let seeded = try await seedRemovableProject(journal, mode: .real, repo: repo, pushedCommit: nil)
    let ref = LandedTipPin.ref(for: removalBranch)
    _ = await repo.run(["update-ref", ref, commit])
    let runID = RunID()
    guard case .claimed = try journal.claimActLease(act: .land, runID: runID, mode: .real, now: removalEpoch) else {
        Issue.record("Could not claim the Act lease")
        return
    }
    try journal.recordLandedCommit(
        featureID: seeded.featureID, repository: "backend", commit: commit, runID: runID, now: removalEpoch
    )
    try journal.releaseActLease(runID: runID)

    let board = FakeWritingBoard()
    await board.seed(issue: seeded.featureIssueID, description: nil)
    let removal = makeRemoval(
        directory: directory, home: home, board: board, workspace: RemovalFakeWorkspace(),
        push: { _, _, _ in .pushed(commit: "deadbeef") }
    )

    #expect(await removal.run(id: "alpha", yes: true))

    #expect(await repo.revParse(ref) == nil)
    #expect(try journal.events(ofType: .landedPinFailed).isEmpty)
    #expect(try journal.landedCommit(featureID: seeded.featureID, repository: "backend") == commit)
}

@Test("A landed pin whose clone is gone is not a failure, and removal still completes")
func removalToleratesAGoneClone() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    let repo = TestGitRepo(name: "removal-landed-pin-gone")
    await repo.initRepo()
    let commit = try await repo.commit()
    _ = await repo.run(["checkout", "-b", removalBranch.name])
    try directory.writeValidProjectFile(id: "alpha", repoPath: repo.path)
    let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)

    let journal = try JournalStore.openSeeded(
        configurationDirectory: directory.url, projectID: try #require(ProjectID(rawValue: "alpha"))
    )
    // No held Worktree: the clone is the only thing the pin lives in.
    let seeded = try await seedRemovableProject(journal, mode: .real, repo: nil)
    let runID = RunID()
    guard case .claimed = try journal.claimActLease(act: .land, runID: runID, mode: .real, now: removalEpoch) else {
        Issue.record("Could not claim the Act lease")
        return
    }
    try journal.recordLandedCommit(
        featureID: seeded.featureID, repository: "backend", commit: commit, runID: runID, now: removalEpoch
    )
    try journal.releaseActLease(runID: runID)
    try FileManager.default.removeItem(at: repo.url)

    let board = FakeWritingBoard()
    await board.seed(issue: seeded.featureIssueID, description: nil)
    let removal = makeRemoval(directory: directory, home: home, board: board)

    #expect(await removal.run(id: "alpha", yes: true))
    #expect(try journal.events(ofType: .landedPinFailed).isEmpty)
}
