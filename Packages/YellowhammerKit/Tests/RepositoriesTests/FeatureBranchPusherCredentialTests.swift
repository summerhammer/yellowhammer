import Domain
import Foundation
@testable import Repositories
import Testing

/// How `FeatureBranchPusher` hands a credential to git, observed through a stub `git` that records its
/// argv and its `GIT_CONFIG_*` environment on `push`.
@Suite("Feature Branch push credentials")
struct FeatureBranchPusherCredentialTests {
    private struct Observed {
        let arguments: [String]
        let environment: [String: String]
        let wholeEnvironment: String
        let updateRef: [String]?
    }

    private static let sshOrigin = "git@github.com:acme/app.git"
    private static let httpsTarget = "https://github.com/acme/app.git"

    private static let sha = "0123456789abcdef0123456789abcdef01234567"

    private func observe(
        _ credential: PushCredential?, origin: String = "/tmp/remote.git"
    ) async throws -> Observed {
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
        *"remote get-url"*)
            echo '\(origin)'
            ;;
        *update-ref*)
            printf '%s\\n' "$@" > '\(directory.path)/update-ref'
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
        let updateRef = try? String(contentsOf: directory.appendingPathComponent("update-ref"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        return Observed(
            arguments: arguments, environment: environment, wholeEnvironment: whole, updateRef: updateRef
        )
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

    @Test("An SSH origin with a token pushes to the explicit HTTPS URL, neutralizing URL rewrites")
    func sshOriginWithTokenPushesToHTTPSURL() async throws {
        let observed = try await observe(.token(GitHubToken("ghp_supersecretvalue")), origin: Self.sshOrigin)

        #expect(observed.arguments.contains(Self.httpsTarget))
        #expect(!observed.arguments.contains("origin"))
        #expect(observed.arguments.last == "refs/heads/yh-project-feature:refs/heads/yh-project-feature")
        #expect(observed.environment["GIT_CONFIG_COUNT"] == "4")
        #expect(observed.environment["GIT_CONFIG_KEY_1"] == "http.extraHeader")
        #expect(observed.environment["GIT_CONFIG_KEY_2"] == "url.\(Self.httpsTarget).insteadOf")
        #expect(observed.environment["GIT_CONFIG_VALUE_2"] == Self.httpsTarget)
        #expect(observed.environment["GIT_CONFIG_KEY_3"] == "url.\(Self.httpsTarget).pushInsteadOf")
        #expect(observed.environment["GIT_CONFIG_VALUE_3"] == Self.httpsTarget)
        let updateRef = try #require(observed.updateRef)
        #expect(updateRef.suffix(2) == ["refs/remotes/origin/yh-project-feature", Self.sha])
        #expect(updateRef.contains("update-ref"))
    }

    @Test("An ssh:// origin with a gh CLI credential pushes to the same HTTPS URL")
    func sshSchemeOriginWithGitHubCLI() async throws {
        let observed = try await observe(
            .githubCLI(executable: "/opt/homebrew/bin/gh"), origin: "ssh://git@github.com/acme/app.git"
        )

        #expect(observed.arguments.contains(Self.httpsTarget))
        #expect(!observed.arguments.contains("origin"))
        #expect(observed.environment["GIT_CONFIG_COUNT"] == "4")
        #expect(observed.updateRef != nil)
    }

    @Test("A non-GitHub origin with a token still pushes to origin, with no URL rewrites or update-ref")
    func nonGitHubOriginPushesToOrigin() async throws {
        let observed = try await observe(.token(GitHubToken("ghp_x")), origin: "/tmp/remote.git")

        #expect(observed.arguments.contains("origin"))
        #expect(observed.environment["GIT_CONFIG_COUNT"] == "2")
        #expect(observed.updateRef == nil)
    }

    @Test("No credential pushes to origin even when origin is an SSH GitHub URL")
    func noCredentialPushesToOrigin() async throws {
        let observed = try await observe(nil, origin: Self.sshOrigin)

        #expect(observed.arguments.contains("origin"))
        #expect(!observed.arguments.contains(Self.httpsTarget))
        #expect(observed.updateRef == nil)
    }

    @Test("The self-mapping beats an Operator's insteadOf rewrite of https://github.com/ to SSH")
    func urlRewriteOverridesBeatOperatorInsteadOf() async throws {
        let fixture = GitFixture(name: "rewrite-\(UUID().uuidString)")
        await fixture.initRepo()
        _ = await fixture.run(["config", "url.git@github.com:.insteadOf", "https://github.com/"])

        let base = ["PATH": "/usr/bin:/bin", "HOME": fixture.path]
        let plain = GitRunner(environment: base)
        let rewritten = await plain.run(["-C", fixture.path, "ls-remote", "--get-url", Self.httpsTarget])
        #expect(rewritten.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == Self.sshOrigin)

        var environment = base
        let overrides = FeatureBranchPusher.urlRewriteOverrides(for: Self.httpsTarget)
        environment["GIT_CONFIG_COUNT"] = "\(overrides.count)"
        for (index, override) in overrides.enumerated() {
            environment["GIT_CONFIG_KEY_\(index)"] = override.key
            environment["GIT_CONFIG_VALUE_\(index)"] = override.value
        }
        let neutralized = await GitRunner(environment: environment)
            .run(["-C", fixture.path, "ls-remote", "--get-url", Self.httpsTarget])
        #expect(neutralized.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == Self.httpsTarget)
    }

    /// `ls-remote --get-url` ignores `pushInsteadOf`, so this runs a real push. `GIT_ALLOW_PROTOCOL=file`
    /// makes git refuse the transport by name before any network I/O, which shows the one it chose.
    @Test("The self-mapping beats an Operator's pushInsteadOf rewrite of https://github.com/ to SSH")
    func urlRewriteOverridesBeatOperatorPushInsteadOf() async throws {
        let fixture = GitFixture(name: "push-rewrite-\(UUID().uuidString)")
        await fixture.initRepo()
        _ = try await fixture.commit(filename: "init.txt", content: "initial", message: "initial commit")
        _ = await fixture.run(["config", "url.git@github.com:.pushInsteadOf", "https://github.com/"])

        let base = ["PATH": "/usr/bin:/bin", "HOME": fixture.path, "GIT_ALLOW_PROTOCOL": "file"]
        let push = ["-C", fixture.path, "push", Self.httpsTarget, "HEAD:refs/heads/yh-project-feature"]
        let rewritten = await GitRunner(environment: base).run(push)
        #expect(rewritten.stderr.contains("transport 'ssh' not allowed"))

        var environment = base
        let overrides = FeatureBranchPusher.urlRewriteOverrides(for: Self.httpsTarget)
        environment["GIT_CONFIG_COUNT"] = "\(overrides.count)"
        for (index, override) in overrides.enumerated() {
            environment["GIT_CONFIG_KEY_\(index)"] = override.key
            environment["GIT_CONFIG_VALUE_\(index)"] = override.value
        }
        let neutralized = await GitRunner(environment: environment).run(push)
        #expect(neutralized.stderr.contains("transport 'https' not allowed"))
    }
}
