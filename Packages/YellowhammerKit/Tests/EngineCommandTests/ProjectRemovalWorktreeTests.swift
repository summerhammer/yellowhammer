import Domain
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Synchronization
import Testing

// Split out of ProjectRemovalTests.swift to keep that file under the file length limit: real-mode
// WIP-commit/push, the Act-Lease refusal, confirmation, no-Journal and re-run scenarios.

@Test("Real mode WIP-commits a dirty Worktree, pushes it, then removes it")
func realModeCommitsAndPushes() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    let repo = TestGitRepo(name: "dirty-real")
    await repo.initRepo()
    _ = try await repo.commit()
    _ = await repo.run(["checkout", "-b", removalBranch.name])
    try "uncommitted".write(
        to: repo.url.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8
    )
    try directory.writeValidProjectFile(id: "alpha", repoPath: repo.path)
    let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)

    let journal = try JournalStore.openSeeded(
        configurationDirectory: directory.url, projectID: try #require(ProjectID(rawValue: "alpha"))
    )
    let seeded = try await seedRemovableProject(journal, mode: .real, repo: repo, pushedCommit: nil)

    let workspace = RemovalFakeWorkspace()
    let board = FakeWritingBoard()
    await board.seed(issue: seeded.featureIssueID, description: nil)
    let pushedBranch = Recorder<FeatureBranch>()
    let removal = makeRemoval(
        directory: directory, home: home, board: board, workspace: workspace,
        push: { branch, _, _ in pushedBranch.record(branch); return .pushed(commit: "deadbeef") }
    )

    let succeeded = await removal.run(id: "alpha", yes: true)

    #expect(succeeded)
    #expect(pushedBranch.value == removalBranch)
    #expect(workspace.removeCalls == [WorktreeID(rawValue: "wt-1")])

    let log = await repo.run(["log", "-1", "--format=%B%an <%ae>"])
    #expect(log.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == """
        chore(wip): preserve uncommitted work on yh-alpha-feat

        Yellowhammer-WIP: yh-alpha-feat
        Yellowhammer <noreply@yellowhammer.dev>
        """)
}

@Test("Removal of a Project with a refused template and change_type still WIP-commits, with the defaults")
func refusedTemplateWritesDefaultWIPCommit() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    let repo = TestGitRepo(name: "dirty-refused-template")
    await repo.initRepo()
    _ = try await repo.commit()
    _ = await repo.run(["checkout", "-b", removalBranch.name])
    try "uncommitted".write(
        to: repo.url.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8
    )
    try directory.writeProjectFile(id: "alpha", """
        id = "alpha"
        name = "alpha"
        board = { linear = { installation = "acme", project = "alpha" } }
        spec_source = "~/Developer/alpha-spec"
        change_type = 7

        [[repos]]
        name = "backend"
        path = "\(repo.path)"
        role = "backend"
        check = "swift test"

        [git]
        wip_commit_message = "wip {title}"
        """)
    let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)
    let journal = try JournalStore.openSeeded(
        configurationDirectory: directory.url, projectID: try #require(ProjectID(rawValue: "alpha"))
    )
    let seeded = try await seedRemovableProject(journal, mode: .real, repo: repo, pushedCommit: nil)
    let board = FakeWritingBoard()
    await board.seed(issue: seeded.featureIssueID, description: nil)
    let output = RecordingOutput()
    let removal = makeRemoval(
        directory: directory, home: home, output: output, board: board, workspace: RemovalFakeWorkspace(),
        push: { _, _, _ in .pushed(commit: "deadbeef") }
    )

    let succeeded = await removal.run(id: "alpha", yes: true)

    #expect(succeeded)
    let log = await repo.run(["log", "-1", "--format=%B%an <%ae>"])
    #expect(log.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == """
        chore(wip): preserve uncommitted work on yh-alpha-feat

        Yellowhammer-WIP: yh-alpha-feat
        Yellowhammer <noreply@yellowhammer.dev>
        """)
    let lines = output.lines.joined(separator: "\n")
    #expect(lines.contains("using the built-in WIP Commit message instead"))
    #expect(lines.contains("using change_type \"feat\" instead"))
}

@Test("A failed push in real mode keeps the Worktree, fails removal, and leaves the Journal untouched")
func realModePushFailureKeepsWorktreeAndFailsRun() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    let repo = TestGitRepo(name: "push-fails")
    await repo.initRepo()
    _ = try await repo.commit()
    _ = await repo.run(["checkout", "-b", removalBranch.name])
    try "uncommitted".write(
        to: repo.url.appendingPathComponent("dirty.txt"), atomically: true, encoding: .utf8
    )
    try directory.writeValidProjectFile(id: "alpha", repoPath: repo.path)
    let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)

    let journal = try JournalStore.openSeeded(
        configurationDirectory: directory.url, projectID: try #require(ProjectID(rawValue: "alpha"))
    )
    let seeded = try await seedRemovableProject(journal, mode: .real, repo: repo, pushedCommit: nil)

    let workspace = RemovalFakeWorkspace()
    let board = FakeWritingBoard()
    await board.seed(issue: seeded.featureIssueID, description: nil)
    let removal = makeRemoval(
        directory: directory, home: home, board: board, workspace: workspace,
        push: { _, repo, _ in .failed(repository: repo.name, reason: "network unreachable") }
    )

    let succeeded = await removal.run(id: "alpha", yes: true)

    #expect(!succeeded)
    #expect(workspace.removeCalls.isEmpty)
    let night = try #require(try journal.currentNight())
    #expect(night.state == .opened)
    #expect(FileManager.default.fileExists(
        atPath: directory.url.appending(components: "projects", "alpha.toml").path(percentEncoded: false)
    ))
}

@Test("Removal is refused while another run holds the Act Lease, and nothing is touched")
func refusedWhileActLeaseHeld() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    let home = try RemovalHomeFixture(projectID: "alpha", plists: true, logs: true)

    let journal = try JournalStore.openSeeded(
        configurationDirectory: directory.url, projectID: try #require(ProjectID(rawValue: "alpha"))
    )
    let holderRunID = RunID()
    guard case .claimed = try journal.claimActLease(act: .build, runID: holderRunID, mode: .real, now: removalEpoch)
    else {
        Issue.record("Could not claim the Act lease")
        return
    }

    let launchAgents = RecordingLaunchAgentControl()
    let removal = makeRemoval(directory: directory, home: home, launchAgents: launchAgents)

    let succeeded = await removal.run(id: "alpha", yes: true)

    #expect(!succeeded)
    #expect(launchAgents.calls.isEmpty)
    for act in Act.allCases {
        #expect(home.plistExists(projectID: "alpha", act: act))
        #expect(home.logExists(projectID: "alpha", act: act))
    }
    #expect(FileManager.default.fileExists(
        atPath: directory.url.appending(components: "projects", "alpha.toml").path(percentEncoded: false)
    ))
}

@Test("A declined confirmation leaves everything untouched")
func declinedConfirmationTouchesNothing() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    let home = try RemovalHomeFixture(projectID: "alpha", plists: true, logs: true)

    let launchAgents = RecordingLaunchAgentControl()
    let console = ScriptedConsole(answers: ["n"])
    let removal = makeRemoval(directory: directory, home: home, console: console, launchAgents: launchAgents)

    let succeeded = await removal.run(id: "alpha", yes: false)

    #expect(!succeeded)
    #expect(launchAgents.calls.isEmpty)
    for act in Act.allCases {
        #expect(home.plistExists(projectID: "alpha", act: act))
    }
    #expect(FileManager.default.fileExists(
        atPath: directory.url.appending(components: "projects", "alpha.toml").path(percentEncoded: false)
    ))
}

@Test("No Journal file: LaunchAgents and logs are removed, the TOML is deleted, no Journal is created")
func noJournalFileStillRemovesMachineFootprint() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    let home = try RemovalHomeFixture(projectID: "alpha", plists: true, logs: true)

    let launchAgents = RecordingLaunchAgentControl()
    let removal = makeRemoval(directory: directory, home: home, launchAgents: launchAgents)

    let succeeded = await removal.run(id: "alpha", yes: true)

    #expect(succeeded)
    for act in Act.allCases {
        #expect(!home.plistExists(projectID: "alpha", act: act))
        #expect(!home.logExists(projectID: "alpha", act: act))
    }
    #expect(!FileManager.default.fileExists(
        atPath: directory.url.appending(components: "projects", "alpha.toml").path(percentEncoded: false)
    ))
    let journalURL = JournalStore.defaultFileURL(
        configurationDirectory: directory.url, id: try #require(ProjectID(rawValue: "alpha"))
    )
    #expect(!FileManager.default.fileExists(atPath: journalURL.path(percentEncoded: false)))
}

@Test("A re-run after a partial failure posts the comment once: the same deterministic clientID replays")
func rerunAfterPartialFailureReplaysTheSameComment() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    let repo = TestGitRepo(name: "retry")
    await repo.initRepo()
    let headCommit = try await repo.commit()
    _ = await repo.run(["checkout", "-b", removalBranch.name])
    try directory.writeValidProjectFile(id: "alpha", repoPath: repo.path)
    let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)

    let journal = try JournalStore.openSeeded(
        configurationDirectory: directory.url, projectID: try #require(ProjectID(rawValue: "alpha"))
    )
    let seeded = try await seedRemovableProject(journal, mode: .rehearsal, repo: repo, pushedCommit: headCommit)

    let board = FakeWritingBoard()
    await board.seed(issue: seeded.featureIssueID, description: nil)
    let workspace = RemovalFakeWorkspace()
    workspace.scriptFailNextRemove()
    let removal = makeRemoval(directory: directory, home: home, board: board, workspace: workspace)

    let firstAttempt = await removal.run(id: "alpha", yes: true)
    #expect(!firstAttempt)
    let commentsAfterFirst = await board.comments
    #expect(commentsAfterFirst.count == 1)

    let secondAttempt = await removal.run(id: "alpha", yes: true)
    #expect(secondAttempt)
    let commentsAfterSecond = await board.comments
    #expect(commentsAfterSecond.count == 1)
}

@Test("An installation missing from the registry skips the release comment and the removal succeeds")
// swiftlint:disable:next function_body_length
func removalWithUndeclaredInstallationSkipsTheComment() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    let repo = TestGitRepo(name: "orphan")
    await repo.initRepo()
    let headCommit = try await repo.commit()
    _ = await repo.run(["checkout", "-b", removalBranch.name])
    try directory.writeProjectFile(id: "alpha", """
        id = "alpha"
        name = "alpha"
        spec_source = "~/Developer/alpha-spec"

        [board.linear]
        installation = "gone"
        project = "alpha"

        [[repos]]
        name = "backend"
        path = "\(repo.path)"
        role = "backend"
        check = "swift test"
        """)
    let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)
    let journal = try JournalStore.openSeeded(
        configurationDirectory: directory.url, projectID: try #require(ProjectID(rawValue: "alpha"))
    )
    let seeded = try await seedRemovableProject(journal, mode: .rehearsal, repo: repo, pushedCommit: headCommit)

    let output = RecordingOutput()
    let workspace = RemovalFakeWorkspace()
    let bound = Recorder<Bool>()
    let removal = ProjectRemoval(
        configurationDirectory: directory.url,
        homeDirectory: home.url,
        output: { output.record($0) },
        console: ScriptedConsole(answers: ["y"]),
        launchAgents: RecordingLaunchAgentControl(),
        bindBoard: { _, _ in
            bound.record(true)
            throw BoardError.notAuthenticated("must not be called")
        },
        workspace: workspace,
        git: GitRunner(),
        bindPush: { _, _ in { _, _, _ in .notPushedInRehearsal } },
        now: removalEpoch
    )

    let succeeded = await removal.run(id: "alpha", yes: true)

    // Spec OQ109 item 10: the skipped comment is a succeeded step. The board is never bound, the skip is
    // reported, the other steps ran, and the removal is recorded.
    #expect(succeeded)
    #expect(bound.value == nil)
    #expect(output.lines.contains {
        $0.contains("skipped the release comment on \(seeded.featureIssueID)")
            && $0.contains("Linear App Installation \"gone\" is not in config.toml")
    })
    #expect(!output.lines.contains { $0.contains("could not comment on") })
    #expect(workspace.removeCalls == [WorktreeID(rawValue: "wt-1")])
    #expect(try journal.events().contains { $0.type == .projectRemoved })
    #expect(!FileManager.default.fileExists(
        atPath: directory.url.appending(components: "projects", "alpha.toml").path(percentEncoded: false)
    ))
}

@Test("A present installation whose authorization Linear refuses still fails the comment step (OQ119)")
func removalWithRefusedInstallationKeepsTheProjectFile() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeValidProjectFile(id: "alpha")
    let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)
    let journal = try JournalStore.openSeeded(
        configurationDirectory: directory.url, projectID: try #require(ProjectID(rawValue: "alpha"))
    )
    _ = try await seedRemovableProject(journal, mode: .rehearsal, repo: nil)

    let output = RecordingOutput()
    let board = FakeWritingBoard()
    await board.refuseNext(.notAuthenticated("sign-in expired"))
    let removal = makeRemoval(directory: directory, home: home, output: output, board: board)

    let succeeded = await removal.run(id: "alpha", yes: true)

    #expect(!succeeded)
    #expect(output.lines.contains { $0.contains("could not comment on FEAT-1") })
    #expect(!output.lines.contains { $0.contains("skipped the release comment") })
    #expect(try !journal.events().contains { $0.type == .projectRemoved })
    #expect(FileManager.default.fileExists(
        atPath: directory.url.appending(components: "projects", "alpha.toml").path(percentEncoded: false)
    ))
}
