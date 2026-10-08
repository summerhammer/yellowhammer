import Domain
import Foundation
import Repositories
import Testing

/// How `FeatureBranchPusher` hands a credential to git, observed through a stub `git` that records its
/// argv and its `GIT_CONFIG_*` environment on `push`.
@Suite("Feature Branch push credentials")
struct FeatureBranchPusherCredentialTests {
    private struct Observed {
        let arguments: [String]
        let environment: [String: String]
        let wholeEnvironment: String
    }

    private static let sha = "0123456789abcdef0123456789abcdef01234567"

    private func observe(_ credential: PushCredential?) async throws -> Observed {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stub-git-\(UUID().uuidString)", isDirectory: true)
        let repoDirectory = directory.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = """
        #!/bin/sh
        case "$*" in
        *" push "*)
            printf '%s\\n' "$@" > '\(directory.path)/argv'
            env > '\(directory.path)/env'
            ;;
        *rev-parse*)
            echo \(Self.sha)
            ;;
        esac
        exit 0
        """
        let git = directory.appendingPathComponent("git")
        try Data(script.utf8).write(to: git)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)

        let repo = Repo(name: "app", path: repoDirectory.path, role: .backend, defaultBranch: "main")
        let runner = GitRunner(executablePath: git.path, environment: ["PATH": "/usr/bin:/bin"])
        let pusher = FeatureBranchPusher(git: runner)
        let outcome = await pusher.push(
            branch: FeatureBranch(name: "yh-project-feature"), in: repo, mode: .real, credential: credential
        )
        #expect(outcome == .pushed(commit: Self.sha))

        let arguments = try String(contentsOf: directory.appendingPathComponent("argv"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let whole = try String(contentsOf: directory.appendingPathComponent("env"), encoding: .utf8)
        var environment: [String: String] = [:]
        for line in whole.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            environment[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return Observed(arguments: arguments, environment: environment, wholeEnvironment: whole)
    }

    @Test("A gh CLI credential resets inherited helpers and installs gh as the helper, with no extraHeader")
    func githubCLIConfiguresCredentialHelper() async throws {
        let observed = try await observe(.githubCLI(executable: "/opt/homebrew/bin/gh"))

        #expect(observed.environment["GIT_CONFIG_COUNT"] == "2")
        #expect(observed.environment["GIT_CONFIG_KEY_0"] == "credential.helper")
        #expect(observed.environment["GIT_CONFIG_VALUE_0"] == "")
        #expect(observed.environment["GIT_CONFIG_KEY_1"] == "credential.helper")
        #expect(observed.environment["GIT_CONFIG_VALUE_1"] == "!'/opt/homebrew/bin/gh' auth git-credential")
        #expect(!observed.wholeEnvironment.contains("http.extraHeader"))
        #expect(observed.environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(!observed.arguments.contains { $0.contains("credential") || $0.contains("auth") })
    }

    @Test("A single quote in the gh path is escaped for the shell")
    func githubCLIPathIsShellQuoted() async throws {
        let observed = try await observe(.githubCLI(executable: "/Users/o'brien/bin/gh"))

        #expect(
            observed.environment["GIT_CONFIG_VALUE_1"] == #"!'/Users/o'\''brien/bin/gh' auth git-credential"#
        )
    }

    @Test("A token credential is unchanged: helpers reset and a basic-auth extraHeader, never in argv")
    func tokenConfiguresExtraHeader() async throws {
        let observed = try await observe(.token(GitHubToken("ghp_supersecretvalue")))

        let basic = Data("x-access-token:ghp_supersecretvalue".utf8).base64EncodedString()
        #expect(observed.environment["GIT_CONFIG_COUNT"] == "2")
        #expect(observed.environment["GIT_CONFIG_KEY_0"] == "credential.helper")
        #expect(observed.environment["GIT_CONFIG_VALUE_0"] == "")
        #expect(observed.environment["GIT_CONFIG_KEY_1"] == "http.extraHeader")
        #expect(observed.environment["GIT_CONFIG_VALUE_1"] == "Authorization: Basic \(basic)")
        #expect(!observed.arguments.contains { $0.contains("supersecretvalue") || $0.contains(basic) })
    }

    @Test("No credential sets no git config at all")
    func noCredentialSetsNoConfig() async throws {
        let observed = try await observe(nil)

        #expect(observed.environment["GIT_CONFIG_COUNT"] == nil)
        #expect(observed.environment["GIT_TERMINAL_PROMPT"] == "0")
    }
}
