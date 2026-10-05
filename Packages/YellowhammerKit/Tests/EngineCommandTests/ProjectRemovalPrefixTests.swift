import Domain
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Testing

// Removal pins the Feature Branch recorded for the Worktree, which Orca ADE may have reported with a
// `<prefix>/` before the requested Worktree name. Split out of ProjectRemovalTests.swift to keep it short.

@Test("Removal pins the recorded prefixed Feature Branch under refs/yellowhammer/removed, not the unprefixed name")
func removalPinsRecordedPrefixedBranch() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    let repo = TestGitRepo(name: "removal-prefix")
    await repo.initRepo()
    let headCommit = try await repo.commit()
    let prefixed = FeatureBranch(name: "rozd/\(removalBranch.name)")
    _ = await repo.run(["checkout", "-b", prefixed.name])
    try directory.writeValidProjectFile(id: "alpha", repoPath: repo.path)
    let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)

    let journal = try JournalStore.openSeeded(
        configurationDirectory: directory.url, projectID: try #require(ProjectID(rawValue: "alpha"))
    )
    let seeded = try await seedRemovableProject(journal, mode: .rehearsal, repo: repo, pushedCommit: nil)
    try journal.recordFeatureBranch(featureID: seeded.featureID, repository: "backend", branch: prefixed)

    let board = FakeWritingBoard()
    await board.seed(issue: seeded.featureIssueID, description: nil)
    let workspace = RemovalFakeWorkspace()
    let removal = makeRemoval(
        directory: directory, home: home, board: board, workspace: workspace,
        push: { _, _, _ in .notPushedInRehearsal }
    )

    let succeeded = await removal.run(id: "alpha", yes: true)

    #expect(succeeded)
    #expect(workspace.removeCalls == [WorktreeID(rawValue: "wt-1")])
    let pinned = await repo.run(["rev-parse", "refs/yellowhammer/removed/\(prefixed.name)"])
    #expect(pinned.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == headCommit)
    let unprefixed = await repo.run(
        ["rev-parse", "--verify", "--quiet", "refs/yellowhammer/removed/\(removalBranch.name)"]
    )
    #expect(unprefixed.exitCode != 0)
}
