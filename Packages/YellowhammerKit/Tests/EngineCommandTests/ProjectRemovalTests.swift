import Domain
import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Repositories
import Synchronization
import Testing

@Test("ProjectRemovalComment names the Project and states nothing on Linear was deleted")
func projectRemovalCommentBody() throws {
    let projectID = try #require(ProjectID(rawValue: "alpha"))
    let body = ProjectRemovalComment(projectID: projectID, mode: .real).body()
    #expect(body.contains("alpha"))
    #expect(body.contains("untouched"))
    #expect(body.contains("WIP"))
    let rehearsal = ProjectRemovalComment(projectID: projectID, mode: .rehearsal).body()
    #expect(rehearsal.contains("never commits or pushes"))
    #expect(!rehearsal.contains("pushed to its Feature Branch"))
}

// `yh project remove <id>` (roadmap P13.5; spec risks.md OQ52(1)). Slice 2: EngineCommand's
// orchestration, built against slice 1's `JournalStore.recordProjectRemoval` (ProjectRemovalTests in
// JournalTests covers slice 1 itself).

let removalEpoch = Date(timeIntervalSince1970: 1_800_000_000)
let removalNightStart = NightStart(rawValue: "2026-09-24")!
let removalBranch = FeatureBranch(rawValue: "yh-alpha-feat")

/// Removes a Worktree by id, scripted to fail its next call (any error but `.worktreeNotFound`) so a
/// test can force one removal attempt to fail and a retry to succeed.
final class RemovalFakeWorkspace: Workspace, @unchecked Sendable {
    private struct State {
        var removeCalls: [WorktreeID] = []
        var failNext = false
    }

    private let state = Mutex(State())

    var removeCalls: [WorktreeID] { state.withLock { $0.removeCalls } }

    func scriptFailNextRemove() {
        state.withLock { $0.failNext = true }
    }

    func createWorktree(
        repositoryPath: String, name: String, baseBranch: String?
    ) async throws(WorkspaceError) -> WorkspaceWorktree {
        throw WorkspaceError.unavailable("RemovalFakeWorkspace never creates a Worktree")
    }

    func worktrees(repositoryPath: String) async throws(WorkspaceError) -> [WorkspaceWorktree] { [] }

    func removeWorktree(id: WorktreeID, force: Bool) async throws(WorkspaceError) {
        state.withLock { $0.removeCalls.append(id) }
        let shouldFail = state.withLock { state in
            let failing = state.failNext
            state.failNext = false
            return failing
        }
        if shouldFail {
            throw WorkspaceError.refused(code: "scripted", message: "scripted failure")
        }
    }
}

/// A home directory with `Library/LaunchAgents` and `Library/Logs/Yellowhammer` pre-created, holding
/// `plistCount` plists and `logCount` logs for `projectID`, named the way `ScheduledJob` names them.
final class RemovalHomeFixture {
    let url: URL

    init(projectID: String, plists: Bool, logs: Bool) throws {
        url = FileManager.default.temporaryDirectory
            .appending(component: "yh-removal-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        let agents = url.appending(components: "Library", "LaunchAgents", directoryHint: .isDirectory)
        let logDirectory = url.appending(components: "Library", "Logs", "Yellowhammer", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        for act in Act.allCases {
            let label = "dev.yellowhammer.\(projectID).\(act.rawValue)"
            if plists {
                try Data().write(to: agents.appending(component: "\(label).plist", directoryHint: .notDirectory))
            }
            if logs {
                // Log file names are `<projectID>.<act>.log` (`ScheduledJob.logPath`), not the LaunchAgent
                // label — the label only names the plist.
                try "log".write(
                    to: logDirectory.appending(
                        component: "\(projectID).\(act.rawValue).log", directoryHint: .notDirectory
                    ),
                    atomically: true, encoding: .utf8
                )
            }
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func plistExists(projectID: String, act: Act) -> Bool {
        let label = "dev.yellowhammer.\(projectID).\(act.rawValue)"
        let plistURL = url.appending(
            components: "Library", "LaunchAgents", "\(label).plist", directoryHint: .notDirectory
        )
        return FileManager.default.fileExists(atPath: plistURL.path(percentEncoded: false))
    }

    func logExists(projectID: String, act: Act) -> Bool {
        let logURL = url.appending(
            components: "Library", "Logs", "Yellowhammer", "\(projectID).\(act.rawValue).log",
            directoryHint: .notDirectory
        )
        return FileManager.default.fileExists(atPath: logURL.path(percentEncoded: false))
    }
}

struct SeededRemovableProject {
    let featureIssueID: String
    let featureID: Int64
    let worktree: WorktreeRecord?
}

/// Claims and releases the Act Lease around inserting a Feature, an open Cycle, an open Night selected
/// in `mode`, and (when `repo` is given) one held Worktree naming `repo`'s directory, on `removalBranch`.
func seedRemovableProject(
    _ journal: JournalStore, mode: NightMode, repo: TestGitRepo?, pushedCommit: String? = .some("")
) async throws -> SeededRemovableProject {
    let runID = RunID()
    guard case .claimed = try journal.claimActLease(act: .author, runID: runID, mode: mode, now: removalEpoch) else {
        struct SetupFailed: Error {}
        throw SetupFailed()
    }
    let opening = try journal.openNight(
        nightStart: removalNightStart, mode: mode, act: .author, runID: runID, now: removalEpoch
    )
    let featureIssueID = "FEAT-1"
    let featureID = try journal.write { db in
        try db.execute(
            sql: "INSERT INTO feature (issue_id, state, created_at, selected_night_id) VALUES (?, ?, ?, ?)",
            arguments: [featureIssueID, "selected", JournalStore.timestamp(removalEpoch), opening.night.id]
        )
        let featureID = db.lastInsertedRowID
        try db.execute(
            sql: "INSERT INTO cycle (feature_id, created_at) VALUES (?, ?)",
            arguments: [featureID, JournalStore.timestamp(removalEpoch)]
        )
        return featureID
    }
    try journal.recordWorktreeName(featureID: featureID, worktreeName: WorktreeName(rawValue: removalBranch.rawValue))

    var worktree: WorktreeRecord?
    if let repo {
        let recorded = try journal.recordWorktree(
            featureID: featureID, repository: "backend", worktreeID: "wt-1", path: repo.path, runID: runID,
            now: removalEpoch
        )
        if let pushedCommit, !pushedCommit.isEmpty {
            worktree = try journal.recordWorktreePush(id: recorded.id, commit: pushedCommit, runID: runID)
        } else {
            worktree = recorded
        }
    }

    try journal.releaseActLease(runID: runID)
    return SeededRemovableProject(featureIssueID: featureIssueID, featureID: featureID, worktree: worktree)
}

/// Records a value written from inside a `@Sendable` closure, so a test can inspect it afterward
/// without mutating a captured local `var` from concurrently-executing code.
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let storage: Mutex<Value?> = Mutex(nil)

    func record(_ value: Value) {
        storage.withLock { $0 = value }
    }

    var value: Value? { storage.withLock { $0 } }
}

func makeRemoval(
    directory: borrowing ConfigurationDirectory,
    home: RemovalHomeFixture,
    output: RecordingOutput = RecordingOutput(),
    console: ScriptedConsole = ScriptedConsole(answers: ["y"]),
    launchAgents: RecordingLaunchAgentControl = RecordingLaunchAgentControl(),
    board: FakeWritingBoard = FakeWritingBoard(),
    workspace: RemovalFakeWorkspace = RemovalFakeWorkspace(),
    push: @escaping @Sendable (FeatureBranch, Repo, NightMode) async -> PushOutcome = { _, _, _ in
        .failed(repository: "backend", reason: "push seam not scripted")
    },
    now: Date = removalEpoch
) -> ProjectRemoval {
    ProjectRemoval(
        configurationDirectory: directory.url,
        homeDirectory: home.url,
        output: { output.record($0) },
        console: console,
        launchAgents: launchAgents,
        bindBoard: { _, _ in board },
        workspace: workspace,
        git: GitRunner(),
        bindPush: { _, _ in push },
        now: now
    )
}

@Test("A fully staged rehearsal removal: LaunchAgents, logs, comment, Worktree, Night, Cycle, event, TOML")
func fullRehearsalRemovalSucceeds() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    let repo = TestGitRepo(name: "clean")
    await repo.initRepo()
    let headCommit = try await repo.commit()
    _ = await repo.run(["checkout", "-b", removalBranch.name])
    try directory.writeValidProjectFile(id: "alpha", repoPath: repo.path)
    let home = try RemovalHomeFixture(projectID: "alpha", plists: true, logs: true)

    let journal = try JournalStore.openSeeded(
        configurationDirectory: directory.url, projectID: try #require(ProjectID(rawValue: "alpha"))
    )
    // A rehearsal Night never pushes, so its Worktree has no recorded push.
    let seeded = try await seedRemovableProject(journal, mode: .rehearsal, repo: repo, pushedCommit: nil)

    let launchAgents = RecordingLaunchAgentControl()
    let board = FakeWritingBoard()
    await board.seed(issue: seeded.featureIssueID, description: nil)
    let workspace = RemovalFakeWorkspace()
    let pushCalled = Recorder<Bool>()
    let removal = makeRemoval(
        directory: directory, home: home, launchAgents: launchAgents, board: board, workspace: workspace,
        push: { _, _, _ in pushCalled.record(true); return .notPushedInRehearsal }
    )

    let succeeded = await removal.run(id: "alpha", yes: true)

    #expect(succeeded)
    #expect(pushCalled.value == nil)
    for act in Act.allCases {
        #expect(launchAgents.calls.contains(.bootout("dev.yellowhammer.alpha.\(act.rawValue)")))
        #expect(!home.plistExists(projectID: "alpha", act: act))
        #expect(!home.logExists(projectID: "alpha", act: act))
    }
    let comments = await board.comments
    #expect(comments.count == 1)
    let comment = try #require(comments.first)
    #expect(comment.issue == BoardObjectID(rawValue: seeded.featureIssueID))
    let removeCalls = workspace.removeCalls
    #expect(removeCalls == [WorktreeID(rawValue: "wt-1")])
    // Never pushed, so the tip is pinned before Orca ADE deletes the local branch with the Worktree.
    let pinned = await repo.run(["rev-parse", "refs/yellowhammer/removed/\(removalBranch.name)"])
    #expect(pinned.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == headCommit)

    let night = try #require(try journal.nights().first)
    #expect(night.closeReason == .projectRemoved)
    let events = try journal.events()
    #expect(events.contains { $0.type == .projectRemoved })
    #expect(!FileManager.default.fileExists(
        atPath: directory.url.appending(components: "projects", "alpha.toml").path(percentEncoded: false)
    ))
    #expect(FileManager.default.fileExists(atPath: journal.fileURL.path(percentEncoded: false)))
}

@Test("A dirty Worktree in rehearsal is kept in place, with a warning, and removal still completes")
func rehearsalDirtyWorktreeIsKept() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    let repo = TestGitRepo(name: "dirty-rehearsal")
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
    let seeded = try await seedRemovableProject(journal, mode: .rehearsal, repo: repo, pushedCommit: nil)

    let workspace = RemovalFakeWorkspace()
    let output = RecordingOutput()
    let board = FakeWritingBoard()
    await board.seed(issue: seeded.featureIssueID, description: nil)
    let removal = makeRemoval(directory: directory, home: home, output: output, board: board, workspace: workspace)

    let succeeded = await removal.run(id: "alpha", yes: true)

    #expect(succeeded)
    #expect(workspace.removeCalls.isEmpty)
    #expect(output.lines.contains { $0.contains("uncommitted edits left in place") })

    let held = try journal.heldWorktrees()
    #expect(held.map(\.repository) == ["backend"])
    guard case .projectRemoved(_, let removedWorktrees, let keptWorktrees) = try #require(
        try journal.events().last(where: { $0.type == .projectRemoved })?.event
    ) else {
        Issue.record("Event should be projectRemoved")
        return
    }
    #expect(removedWorktrees.isEmpty)
    #expect(keptWorktrees == ["backend"])
}

@Test("A Project refused at load for an invalid template is refused by normal resolution but still removed")
func invalidTemplateProjectIsRemovable() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeProjectFile(id: "alpha", """
        id = "alpha"
        name = "alpha"
        board = { linear = { connection = "acme", project = "alpha" } }
        spec_source = "~/Developer/alpha-spec"
        change_type = ""

        [[repos]]
        name = "backend"
        path = "~/Developer/alpha-backend"
        role = "backend"
        check = "none"

        [git]
        wip_commit_message = "wip {title}"
        """)
    let home = try RemovalHomeFixture(projectID: "alpha", plists: true, logs: true)

    #expect(throws: ProjectResolutionError.self) {
        try ProjectResolution.resolve(projectArgument: "alpha", configurationDirectory: directory.url)
    }
    let (_, lenient) = try ProjectResolution.resolve(
        projectArgument: "alpha", configurationDirectory: directory.url, lenientTemplates: true
    )
    #expect(lenient.wipCommitMessage == .default(.wipCommitMessage))
    #expect(lenient.unvalidatedTemplates?.wipCommitMessage == "wip {title}")
    #expect(lenient.unvalidatedTemplates?.changeType == "")
    #expect(lenient.unvalidatedTemplates?.refusals.count == 2)

    let output = RecordingOutput()
    let removal = makeRemoval(directory: directory, home: home, output: output)
    let succeeded = await removal.run(id: "alpha", yes: true)

    #expect(succeeded)
    #expect(!FileManager.default.fileExists(
        atPath: directory.url.appending(components: "projects", "alpha.toml").path(percentEncoded: false)
    ))
}

@Test("Removal still refuses a Project whose repos are invalid, template or not")
func removalStillValidatesWhatItUses() async throws {
    let directory = ConfigurationDirectory()
    try directory.writeMachineFile()
    try directory.writeProjectFile(id: "alpha", """
        id = "alpha"
        name = "alpha"
        board = { linear = { connection = "acme", project = "alpha" } }
        spec_source = "~/Developer/alpha-spec"

        [git]
        commit_message = "{nope}"
        """)
    let home = try RemovalHomeFixture(projectID: "alpha", plists: false, logs: false)
    let output = RecordingOutput()
    let removal = makeRemoval(directory: directory, home: home, output: output)

    let succeeded = await removal.run(id: "alpha", yes: true)

    #expect(!succeeded)
    #expect(FileManager.default.fileExists(
        atPath: directory.url.appending(components: "projects", "alpha.toml").path(percentEncoded: false)
    ))
}
