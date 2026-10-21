import Domain
@testable import Engine
import Foundation
import Journal
import Repositories

// Every Worktree of a Feature is cut from the base recorded at selection, and allocation without one is a fault
// (feature-authoring/select-the-next-feature `#effective-base`). These helpers give a fixture Feature that record:
// a real repository whose HEAD is the base, and a Workspace stub that cuts a Worktree from the base it is handed.

/// Initialises a real git repository at `directory` with one commit on `main` and returns the commit's SHA.
@discardableResult
func initRecordedBaseRepo(at directory: URL) async throws -> String {
    try await initReconcilerGitRepo(at: directory)
}

/// A real repository `name` under `root/repos` whose HEAD is recorded as `featureID`'s base there.
func seedRecordedBaseRepo(
    _ journal: JournalStore, featureID: Int64, name: String, role: RepoRole, under root: URL
) async throws -> Repo {
    let directory = root.appendingPathComponent("repos").appendingPathComponent(name)
    let commit = try await initRecordedBaseRepo(at: directory)
    try journal.recordFeatureBases(featureID: featureID, bases: [
        FeatureBaseRecord(repository: name, baseRef: "refs/heads/main", baseCommit: commit)
    ])
    return Repo(name: name, path: directory.path, role: role)
}

/// Cuts a Worktree the way Orca ADE does when handed a base: detached at `baseBranch`, then attached to `branch`.
/// Returns git's stderr on failure.
func addWorktreeFromBase(
    repositoryPath: String, directory: URL, baseBranch: String, branch: String
) async -> String? {
    let git = GitRunner()
    let added = await git.run([
        "-C", repositoryPath, "worktree", "add", "--detach", directory.path, baseBranch
    ])
    guard added.isSuccess else { return added.stderr }
    let attached = await git.run(["-C", directory.path, "checkout", "-B", branch])
    return attached.isSuccess ? nil : attached.stderr
}

/// Records the current HEAD of the real repository `repo` as `featureID`'s base there.
func recordHeadAsBase(_ journal: JournalStore, featureID: Int64, repo: Repo) async throws {
    let head = await GitRunner().run(["-C", repo.path, "rev-parse", "HEAD"])
    try journal.recordFeatureBases(featureID: featureID, bases: [
        FeatureBaseRecord(
            repository: repo.name, baseRef: "refs/heads/main",
            baseCommit: head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    ])
}

/// `selectionRepositories()` backed by real git repositories under `root`, so an `EngineInvocation` resolves a
/// mainline for each and the author Act can record the bases it selects against.
func realSelectionRepositories(under root: URL) async throws -> ProjectRepositories {
    var workingRepos: [Repo] = []
    for (name, role) in [("backend", RepoRole.backend), ("mobile", RepoRole.mobile)] {
        let directory = root.appendingPathComponent(name)
        try await initRecordedBaseRepo(at: directory)
        workingRepos.append(Repo(name: name, path: directory.path, role: role))
    }
    return ProjectRepositories(workingRepos: workingRepos, specSource: SpecSource(path: "/repos/spec"))
}

/// ``seedRecordedBaseRepo(_:featureID:name:role:under:)`` for the fixture `backend` repository.
func seedBackendRepo(_ journal: JournalStore, featureID: Int64, under root: URL) async throws -> Repo {
    try await seedRecordedBaseRepo(journal, featureID: featureID, name: "backend", role: .backend, under: root)
}

/// ``seedRecordedBaseRepo(_:featureID:name:role:under:)`` for the fixture `mobile` repository.
func seedMobileRepo(_ journal: JournalStore, featureID: Int64, under root: URL) async throws -> Repo {
    try await seedRecordedBaseRepo(journal, featureID: featureID, name: "mobile", role: .mobile, under: root)
}
