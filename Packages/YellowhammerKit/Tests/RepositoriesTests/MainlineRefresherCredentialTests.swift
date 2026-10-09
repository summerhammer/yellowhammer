import Domain
import Foundation
import Repositories
import Synchronization
import Testing

/// How `MainlineRefresher` authenticates its Act-start fetch, observed through a stub `git` that records
/// its argv and environment on `fetch`.
@Suite("Mainline fetch credentials")
struct MainlineRefresherCredentialTests {
    private struct Observed {
        let fetched: Bool
        let arguments: [String]
        let environment: [String: String]
        let wholeEnvironment: String
        let mainline: ResolvedMainline?
        let failures: [MainlineFetchFailure]
    }

    private struct ResolutionFailure: Error, CustomStringConvertible {
        let description = "connection refused for the test"
    }

    private static let sha = "0123456789abcdef0123456789abcdef01234567"

    private func makeStub(in directory: URL, origin: String) throws -> URL {
        let script = """
        #!/bin/sh
        case "$*" in
        *" fetch "*)
            printf '%s\\n' "$@" >> '\(directory.path)/argv'
            env >> '\(directory.path)/env'
            ;;
        *" remote")
            echo origin
            ;;
        *"remote get-url"*)
            echo '\(origin)'
            ;;
        *rev-parse*)
            echo \(Self.sha)
            ;;
        *symbolic-ref*)
            exit 1
            ;;
        esac
        exit 0
        """
        let git = directory.appendingPathComponent("git")
        try Data(script.utf8).write(to: git)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)
        return git
    }

    private func makeRefresher(
        directory: URL, origin: String = "/tmp/remote.git",
        credential: @escaping @Sendable () throws -> PushCredential?
    ) throws -> (MainlineRefresher, Repo) {
        let repoDirectory = directory.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDirectory, withIntermediateDirectories: true)
        let git = try makeStub(in: directory, origin: origin)
        let runner = GitRunner(executablePath: git.path, environment: ["PATH": "/usr/bin:/bin"])
        let repo = Repo(name: "app", path: repoDirectory.path, role: .backend, defaultBranch: "main")
        return (MainlineRefresher(git: runner, credential: credential), repo)
    }

    private func observe(
        origin: String = "/tmp/remote.git", _ credential: @escaping @Sendable () throws -> PushCredential?
    ) async throws -> Observed {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stub-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (refresher, repo) = try makeRefresher(directory: directory, origin: origin, credential: credential)

        let result = await refresher.refreshWorkingRepo(repo)

        let argvURL = directory.appendingPathComponent("argv")
        let fetched = FileManager.default.fileExists(atPath: argvURL.path)
        let arguments = fetched
            ? try String(contentsOf: argvURL, encoding: .utf8).split(separator: "\n").map(String.init) : []
        let whole = fetched
            ? try String(contentsOf: directory.appendingPathComponent("env"), encoding: .utf8) : ""
        var environment: [String: String] = [:]
        for line in whole.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            environment[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return Observed(
            fetched: fetched, arguments: arguments, environment: environment, wholeEnvironment: whole,
            mainline: result.mainline, failures: result.failure.map { [$0] } ?? []
        )
    }

    @Test("A token credential fetches with a basic-auth extraHeader in the environment, never in argv")
    func tokenConfiguresExtraHeader() async throws {
        let observed = try await observe { .token(GitHubToken("ghp_supersecretvalue")) }

        let basic = Data("x-access-token:ghp_supersecretvalue".utf8).base64EncodedString()
        #expect(observed.fetched)
        #expect(observed.environment["GIT_CONFIG_COUNT"] == "2")
        #expect(observed.environment["GIT_CONFIG_KEY_0"] == "credential.helper")
        #expect(observed.environment["GIT_CONFIG_VALUE_0"] == "")
        #expect(observed.environment["GIT_CONFIG_KEY_1"] == "http.extraHeader")
        #expect(observed.environment["GIT_CONFIG_VALUE_1"] == "Authorization: Basic \(basic)")
        #expect(observed.environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(observed.environment["GIT_ASKPASS"] == "")
        #expect(!observed.arguments.contains { $0.contains("supersecretvalue") || $0.contains(basic) })
        #expect(observed.arguments.contains("fetch") && observed.arguments.contains("origin"))
        #expect(observed.failures.isEmpty)
    }

    @Test("A gh CLI credential resets inherited helpers and installs gh as the helper")
    func githubCLIConfiguresCredentialHelper() async throws {
        let observed = try await observe { .githubCLI(executable: "/opt/homebrew/bin/gh") }

        #expect(observed.fetched)
        #expect(observed.environment["GIT_CONFIG_COUNT"] == "2")
        #expect(observed.environment["GIT_CONFIG_KEY_0"] == "credential.helper")
        #expect(observed.environment["GIT_CONFIG_VALUE_0"] == "")
        #expect(observed.environment["GIT_CONFIG_KEY_1"] == "credential.helper")
        #expect(observed.environment["GIT_CONFIG_VALUE_1"] == "!'/opt/homebrew/bin/gh' auth git-credential")
        #expect(!observed.wholeEnvironment.contains("http.extraHeader"))
        #expect(observed.environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(observed.environment["GIT_ASKPASS"] == "")
        #expect(!observed.arguments.contains { $0.contains("credential") || $0.contains("auth") })
    }

    @Test("An SSH GitHub origin with a credential fetches from the HTTPS URL into origin's tracking ref")
    func sshOriginFetchesOverHTTPS() async throws {
        let target = "https://github.com/acme/app.git"
        let observed = try await observe(origin: "git@github.com:acme/app.git") {
            .githubCLI(executable: "/opt/homebrew/bin/gh")
        }

        #expect(observed.fetched)
        #expect(observed.arguments.suffix(2) == [target, "+refs/heads/main:refs/remotes/origin/main"])
        #expect(!observed.arguments.contains("origin"))
        #expect(observed.environment["GIT_CONFIG_COUNT"] == "4")
        #expect(observed.environment["GIT_CONFIG_KEY_2"] == "url.\(target).insteadOf")
        #expect(observed.environment["GIT_CONFIG_KEY_3"] == "url.\(target).pushInsteadOf")
        #expect(observed.mainline?.ref == "refs/remotes/origin/main")
    }

    @Test("An SSH GitHub origin with no credential still fetches from origin")
    func sshOriginWithoutCredentialFetchesOrigin() async throws {
        let observed = try await observe(origin: "git@github.com:acme/app.git") { nil }

        #expect(observed.arguments.suffix(2) == ["origin", "main"])
        #expect(observed.environment["GIT_CONFIG_COUNT"] == nil)
    }

    @Test("A credential that cannot be resolved runs no fetch, records the failure and falls back to the cached ref")
    func unresolvableCredentialNeverFetches() async throws {
        let observed = try await observe { throw ResolutionFailure() }

        #expect(!observed.fetched)
        let failure = try #require(observed.failures.first)
        #expect(failure.repository == "app")
        #expect(failure.reason.contains("Code Hosting Connection"))
        #expect(failure.reason.contains("connection refused for the test"))
        #expect(!failure.reason.contains("ghp_"))
        #expect(observed.mainline?.ref == "refs/remotes/origin/main")
        #expect(observed.mainline?.commit == Self.sha)
    }

    @Test("Refreshing a Project's repositories resolves the credential exactly once")
    func refreshResolvesOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stub-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let calls = Mutex(0)
        let (refresher, first) = try makeRefresher(directory: directory) {
            calls.withLock { $0 += 1 }
            return .token(GitHubToken("ghp_supersecretvalue"))
        }
        let secondDirectory = directory.appendingPathComponent("repo2", isDirectory: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let second = Repo(name: "web", path: secondDirectory.path, role: .backend, defaultBranch: "main")

        let result = await refresher.refresh(
            repositories: ProjectRepositories(workingRepos: [first, second], specSource: nil)
        )

        #expect(calls.withLock { $0 } == 1)
        #expect(result.mainlines.workingRepos.count == 2)
        #expect(result.failures.isEmpty)
    }
}
