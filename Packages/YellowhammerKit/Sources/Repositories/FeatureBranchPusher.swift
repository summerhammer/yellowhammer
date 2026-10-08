import Domain
import Foundation

/// The outcome of pushing a Feature Branch to GitHub.
public enum PushOutcome: Equatable, Sendable {
    /// The push succeeded; `commit` is the pushed branch tip.
    case pushed(commit: String)
    /// GitHub's branch protection rejected the push. Never carries the credential.
    case refusedByBranchProtection(repository: String, detail: String)
    /// The credential is missing or insufficient for the push. Never carries the credential.
    case credentialsMissingOrInsufficient(repository: String, detail: String)
    /// Rehearsal never pushes; no git command was run.
    case notPushedInRehearsal
    /// Refused before running any push: the branch is the repository's Mainline.
    case refusedMainline
    /// Anything else: a missing repository, an unresolvable branch, a network failure, and so on.
    case failed(repository: String, reason: String)
}

/// The classification of a failed `git push`'s exit code and stderr.
public enum PushFailureClassification: Equatable, Sendable {
    case branchProtection
    case credentials
    case other
}

/// How a push authenticates to GitHub.
public enum PushCredential: Sendable {
    /// A token Yellowhammer holds, sent as a basic-auth `http.extraHeader`.
    case token(GitHubToken)
    /// The Operator's own GitHub CLI at `executable` (an absolute path) as git's credential helper
    /// (`gh auth git-credential`): the token passes from `gh` to git and never enters this process.
    case githubCLI(executable: String)
}

/// Pushes a Feature Branch to `origin` on GitHub.
///
/// Rehearsal never pushes (`.notPushedInRehearsal`, no git command run). Mainline is never
/// pushed (`.refusedMainline`, no git command run). A credential, when given, is supplied to git
/// entirely through environment-based config (`GIT_CONFIG_COUNT`/`_KEY_n`/`_VALUE_n`), never as
/// a process argument: a token becomes an `http.extraHeader`, a `gh` CLI becomes the
/// `credential.helper`. The credential itself never appears in an outcome.
public struct FeatureBranchPusher: Sendable {
    public let git: GitRunner

    public init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    public func push(
        branch: FeatureBranch,
        in repo: Repo,
        mode: NightMode,
        credential: PushCredential?
    ) async -> PushOutcome {
        if mode == .rehearsal {
            return .notPushedInRehearsal
        }

        let path = (repo.path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return .failed(repository: repo.name, reason: "repository path does not exist: \(repo.path)")
        }

        let defaultBranch: String
        if let override = repo.defaultBranch, !override.isEmpty {
            defaultBranch = override
        } else {
            defaultBranch = await MainlineRefresher(git: git).resolveDefaultBranch(for: repo, in: path)
        }
        guard branch.name != defaultBranch else {
            return .refusedMainline
        }

        let pushRunner = pushRunner(credential: credential)
        let refspec = "refs/heads/\(branch.name):refs/heads/\(branch.name)"
        let result = await pushRunner.run(["-C", path, "push", "--porcelain", "origin", refspec])

        guard result.isSuccess else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            switch Self.classify(exitCode: result.exitCode, stderr: stderr) {
            case .branchProtection:
                return .refusedByBranchProtection(repository: repo.name, detail: stderr)
            case .credentials:
                return .credentialsMissingOrInsufficient(repository: repo.name, detail: stderr)
            case .other:
                return .failed(repository: repo.name, reason: stderr)
            }
        }

        guard let commit = await revParse("refs/heads/\(branch.name)", in: path) else {
            return .failed(repository: repo.name, reason: "push succeeded but the branch tip could not be resolved")
        }
        return .pushed(commit: commit)
    }

    /// Builds the `GitRunner` used for the push: ambient environment plus a disabled terminal
    /// prompt, and, when a credential is given, config injected purely through the environment so
    /// no credential appears in `ps`/process arguments.
    private func pushRunner(credential: PushCredential?) -> GitRunner {
        var environment = git.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"

        if let credential {
            let configs = Self.configs(for: credential)
            environment["GIT_CONFIG_COUNT"] = "\(configs.count)"
            for (index, config) in configs.enumerated() {
                environment["GIT_CONFIG_KEY_\(index)"] = config.key
                environment["GIT_CONFIG_VALUE_\(index)"] = config.value
            }
        }

        return GitRunner(executablePath: git.executablePath, environment: environment)
    }

    /// The git config pairs for a credential. Both reset the inherited `credential.helper` list first.
    private static func configs(for credential: PushCredential) -> [(key: String, value: String)] {
        switch credential {
        case .token(let token):
            let basicCredential = Data("x-access-token:\(token.value)".utf8).base64EncodedString()
            return [
                (key: "credential.helper", value: ""),
                (key: "http.extraHeader", value: "Authorization: Basic \(basicCredential)")
            ]
        case .githubCLI(let executable):
            // A shell-run helper (leading `!`): the path is single-quoted, with `'` written as `'\''`.
            let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
            return [
                (key: "credential.helper", value: ""),
                (key: "credential.helper", value: "!\(quoted) auth git-credential")
            ]
        }
    }

    private func revParse(_ ref: String, in path: String) async -> String? {
        let result = await git.run(["-C", path, "rev-parse", "--verify", "--quiet", "\(ref)^{commit}"])
        guard result.isSuccess else { return nil }
        let sha = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// Classifies a failed push's exit code and stderr.
    ///
    /// Credential markers are checked before branch-protection markers: GitHub sometimes phrases
    /// an authorization failure using rejection wording ("[remote rejected]") that a protection
    /// response can also use, and a credential failure is the more specific, more actionable
    /// diagnosis when both kinds of marker are present.
    public static func classify(exitCode: Int32, stderr: String) -> PushFailureClassification {
        guard exitCode != 0 else { return .other }

        let credentialMarkers = [
            "Authentication failed",
            "could not read Username",
            "terminal prompts disabled",
            "Permission to",
            "denied to",
            // Anchored: a bare "403" can occur inside a commit SHA on a `remote:` line.
            "error: 403",
            "Invalid username or password",
            "Permission denied (publickey)"
        ]
        if credentialMarkers.contains(where: { stderr.contains($0) }) {
            return .credentials
        }

        let branchProtectionMarkers = [
            "protected branch",
            "GH006",
            "pre-receive hook declined",
            "[remote rejected]"
        ]
        if branchProtectionMarkers.contains(where: { stderr.contains($0) }) {
            return .branchProtection
        }

        return .other
    }
}
