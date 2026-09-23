import Domain
import Foundation
import Repositories
import Testing

@Suite("MainlineReader tests")
struct MainlineReaderTests {

    @Test("Reads file from working repo at mainline head commit")
    func workingRepoRead() async throws {
        let fixture = GitFixture(name: "mlr-working-repo-1")
        await fixture.initRepo(defaultBranch: "main")
        let sha = try await fixture.commit(filename: "src/api.swift", content: "protocol API { func ping() }")

        let repo = Repo(name: "backend", path: fixture.path, role: .backend)
        let repos = ProjectRepositories(workingRepos: [repo])
        let reader = MainlineReader()

        let read = try await reader.readFile(
            path: "src/api.swift",
            repository: "backend",
            in: repos
        )
        #expect(read.content == "protocol API { func ping() }")
        #expect(read.commit == sha)
        #expect(read.repository == "backend")
        #expect(read.path == "src/api.swift")
    }

    @Test("Reads file from SpecSource at mainline head commit")
    func specSourceRead() async throws {
        let fixture = GitFixture(name: "mlr-spec-source-2")
        await fixture.initRepo(defaultBranch: "main")
        let sha = try await fixture.commit(filename: "docs/spec.md", content: "# Architecture Spec")

        let specSource = SpecSource(path: fixture.path)
        let repos = ProjectRepositories(workingRepos: [], specSource: specSource)
        let reader = MainlineReader()

        let read = try await reader.readFile(
            path: "docs/spec.md",
            repository: "spec_source",
            in: repos
        )
        #expect(read.content == "# Architecture Spec")
        #expect(read.commit == sha)
        #expect(read.repository == "spec_source")
        #expect(read.path == "docs/spec.md")
    }

    @Test("Reads file with explicit commit SHA (time travel)")
    func explicitCommitRead() async throws {
        let fixture = GitFixture(name: "mlr-explicit-commit-3")
        await fixture.initRepo(defaultBranch: "main")
        let sha1 = try await fixture.commit(filename: "contract.json", content: "{\"version\": 1}")
        let sha2 = try await fixture.commit(filename: "contract.json", content: "{\"version\": 2}")

        let repo = Repo(name: "service", path: fixture.path, role: .backend)
        let repos = ProjectRepositories(workingRepos: [repo])
        let reader = MainlineReader()

        let read1 = try await reader.readFile(
            path: "contract.json",
            repository: "service",
            in: repos,
            commit: sha1
        )
        #expect(read1.content == "{\"version\": 1}")
        #expect(read1.commit == sha1)

        let read2 = try await reader.readFile(
            path: "contract.json",
            repository: "service",
            in: repos,
            commit: sha2
        )
        #expect(read2.content == "{\"version\": 2}")
        #expect(read2.commit == sha2)
    }

    @Test("Reads file using pinned ResolvedMainlines")
    func pinnedResolvedMainlinesRead() async throws {
        let fixture = GitFixture(name: "mlr-pinned-mainlines-4")
        await fixture.initRepo(defaultBranch: "main")
        let sha1 = try await fixture.commit(filename: "data.txt", content: "first")
        _ = try await fixture.commit(filename: "data.txt", content: "second")

        let repo = Repo(name: "store", path: fixture.path, role: .backend)
        let repos = ProjectRepositories(workingRepos: [repo])
        let pinnedMainline = ResolvedMainline(
            repository: "store",
            defaultBranch: "main",
            ref: "refs/heads/main",
            commit: sha1
        )
        let mainlines = ResolvedMainlines(workingRepos: ["store": pinnedMainline])
        let reader = MainlineReader()

        let read = try await reader.readFile(
            path: "data.txt",
            repository: "store",
            in: repos,
            mainlines: mainlines
        )
        #expect(read.content == "first")
        #expect(read.commit == sha1)
    }

    @Test("Transcribes single and multiple files into TranscriptionBlock")
    func transcriptionBlockCreation() async throws {
        let fixture = GitFixture(name: "mlr-transcribe-5")
        await fixture.initRepo(defaultBranch: "main")
        _ = try await fixture.commit(filename: "contracts/user.swift", content: "struct User { let id: String }")
        let sha = try await fixture.commit(
            filename: "contracts/auth.swift", content: "struct Auth { let token: String }"
        )

        let repo = Repo(name: "contracts-repo", path: fixture.path, role: .backend)
        let repos = ProjectRepositories(workingRepos: [repo])
        let reader = MainlineReader()

        let block = try await reader.transcribe(
            paths: ["contracts/user.swift", "contracts/auth.swift"],
            repository: "contracts-repo",
            in: repos,
            symbol: "Auth"
        )
        #expect(block.repository == "contracts-repo")
        #expect(block.paths == ["contracts/user.swift", "contracts/auth.swift"])
        #expect(block.symbol == "Auth")
        #expect(block.mainlineCommit == sha)
        #expect(block.authorSupplied == false)
        #expect(block.authorSuppliedNight == nil)
        #expect(block.content.contains("struct User"))
        #expect(block.content.contains("struct Auth"))
        #expect(block.contentHash == MainlineReader.sha256(block.content))
    }

    @Test("Refuses read of repository outside Project configuration")
    func unconfiguredRepositoryRefusal() async throws {
        let fixture = GitFixture(name: "mlr-unconfigured-6")
        await fixture.initRepo(defaultBranch: "main")
        try await fixture.commit(filename: "file.txt", content: "secret")

        let repos = ProjectRepositories(workingRepos: [])
        let reader = MainlineReader()

        await #expect(throws: MainlineReadError.unconfiguredRepository("unconfigured-repo")) {
            try await reader.readFile(
                path: "file.txt",
                repository: "unconfigured-repo",
                in: repos
            )
        }
    }

    @Test("Refuses a path in another Project's repository")
    func foreignProjectRepositoryRefusal() async throws {
        let fixtureA = GitFixture(name: "mlr-project-a")
        await fixtureA.initRepo(defaultBranch: "main")
        try await fixtureA.commit(filename: "src/service.swift", content: "struct ServiceA {}")

        let fixtureB = GitFixture(name: "mlr-project-b")
        await fixtureB.initRepo(defaultBranch: "main")
        try await fixtureB.commit(filename: "src/secret.swift", content: "struct SecretB {}")

        let repoA = Repo(name: "service-a", path: fixtureA.path, role: .backend)
        let projectARepos = ProjectRepositories(workingRepos: [repoA])
        let reader = MainlineReader()

        // 1. Calling by repo name from Project B fails in Project A
        await #expect(throws: MainlineReadError.unconfiguredRepository("service-b")) {
            try await reader.readFile(
                path: "src/secret.swift",
                repository: "service-b",
                in: projectARepos
            )
        }

        // 2. Calling by path of Project B repo fails in Project A
        await #expect(throws: MainlineReadError.unconfiguredRepository(fixtureB.path)) {
            try await reader.readFile(
                path: "src/secret.swift",
                repository: fixtureB.path,
                in: projectARepos
            )
        }

        // 3. Passing an absolute path targeting Project B file into Project A's repo fails
        let foreignFilePath = fixtureB.url.appendingPathComponent("src/secret.swift").path
        await #expect(throws: MainlineReadError.pathEscapesRepository(foreignFilePath)) {
            try await reader.readFile(
                path: foreignFilePath,
                repository: "service-a",
                in: projectARepos
            )
        }
    }

    @Test("Refuses path traversal escaping repository root")
    func pathTraversalRefusal() async throws {
        let fixture = GitFixture(name: "mlr-traversal-7")
        await fixture.initRepo(defaultBranch: "main")
        try await fixture.commit(filename: "docs/file.txt", content: "data")

        let repo = Repo(name: "safe-repo", path: fixture.path, role: .backend)
        let repos = ProjectRepositories(workingRepos: [repo])
        let reader = MainlineReader()

        await #expect(throws: MainlineReadError.pathEscapesRepository("../outside.txt")) {
            try await reader.readFile(
                path: "../outside.txt",
                repository: "safe-repo",
                in: repos
            )
        }

        await #expect(throws: MainlineReadError.pathEscapesRepository("docs/../../outside.txt")) {
            try await reader.readFile(
                path: "docs/../../outside.txt",
                repository: "safe-repo",
                in: repos
            )
        }

        await #expect(throws: MainlineReadError.pathEscapesRepository("/etc/passwd")) {
            try await reader.readFile(
                path: "/etc/passwd",
                repository: "safe-repo",
                in: repos
            )
        }
    }

    @Test("Reports missing repository, unresolvable commit, and file not found errors")
    func missingErrors() async throws {
        let fixture = GitFixture(name: "mlr-errors-8")
        await fixture.initRepo(defaultBranch: "main")
        let sha = try await fixture.commit(filename: "exists.txt", content: "hello")

        let missingRepo = Repo(name: "missing", path: "/non/existent/repo/path", role: .backend)
        let validRepo = Repo(name: "valid", path: fixture.path, role: .backend)
        let repos = ProjectRepositories(workingRepos: [missingRepo, validRepo])
        let reader = MainlineReader()

        // 1. Missing repository directory
        await #expect(throws: MainlineReadError.self) {
            try await reader.readFile(
                path: "exists.txt",
                repository: "missing",
                in: repos
            )
        }

        // 2. Unresolvable commit
        let badCommit = "badbeef000000000000000000000000000000000"
        await #expect(throws: MainlineReadError.unresolvableCommit(repository: "valid", commit: badCommit)) {
            try await reader.readFile(
                path: "exists.txt",
                repository: "valid",
                in: repos,
                commit: badCommit
            )
        }

        // 3. File not found
        await #expect(throws: MainlineReadError.fileNotFound(path: "missing.txt", commit: sha, repository: "valid")) {
            try await reader.readFile(
                path: "missing.txt",
                repository: "valid",
                in: repos,
                commit: sha
            )
        }
    }
}
