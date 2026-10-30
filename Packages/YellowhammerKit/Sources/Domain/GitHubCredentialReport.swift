import Foundation

/// What checking the GitHub credential found: the single shared shape the engine encodes (one compact JSON
/// object on the command's last line) and the app decodes, so the two can never drift. The raw values of
/// ``State``, ``RepoStatus`` and ``PullRequestReadStatus`` are a contract with the app.
///
/// It never carries the token. Every ``message`` is a sentence for the Operator.
public struct GitHubCredentialReport: Codable, Equatable, Sendable {
    /// Whether the credential could be used at all.
    public enum State: String, Codable, Equatable, Sendable {
        /// The Keychain item was read and GitHub accepted the token.
        case resolves
        /// No Keychain item under the reference.
        case missing
        /// The Keychain item may exist but could not be read (a locked Keychain).
        case unreadable
        /// GitHub refused the token (revoked, expired or wrong).
        case rejected
        /// GitHub could not be asked, or gave no verdict.
        case unreachable
    }

    /// What the token can do on one Repo.
    public enum RepoStatus: String, Codable, Equatable, Sendable {
        /// The token can push.
        case ok
        /// The user can push, but a fine-grained token's own grants cannot be confirmed without writing.
        case okUnverified
        case noPushPermission
        case missingScope
        case notFound
        /// The Repo's `origin` is not a GitHub repository.
        case notGitHub
        case unreachable
        case rejected
    }

    /// Whether the credential can read pull requests on one Repo, for the merge test's pull request read
    /// (shift-scheduling/diagnose-the-installation, `#check-5-code-hosting-connections-github`). Only `yh doctor`
    /// asks; it never decides ``isValid``, which is about pushing.
    public struct PullRequestRead: Codable, Equatable, Sendable {
        public var status: PullRequestReadStatus
        public var message: String

        public init(status: PullRequestReadStatus, message: String) {
            self.status = status
            self.message = message
        }
    }

    /// Whether the credential could read pull requests on one Repo.
    public enum PullRequestReadStatus: String, Codable, Equatable, Sendable {
        /// A pull request list was read.
        case canRead
        /// GitHub refused the read (no access, or the credential refused for it).
        case cannotRead
        /// GitHub gave no verdict: unreachable, rate limited, or an answer that could not be read.
        case unverified
    }

    /// One working Repo's verdict.
    public struct Repo: Codable, Equatable, Sendable {
        public var name: String
        public var path: String
        /// `owner/name`, when the Repo's `origin` named a GitHub repository.
        public var slug: String?
        /// Whether the credential can push: the Repo's verdict.
        public var status: RepoStatus
        public var message: String
        /// Whether the credential can read pull requests; nil when it was not asked (only `yh doctor` asks) or
        /// the Repo is not a GitHub repository.
        public var pullRequestRead: PullRequestRead?

        public init(
            name: String, path: String, slug: String? = nil, status: RepoStatus, message: String,
            pullRequestRead: PullRequestRead? = nil
        ) {
            self.name = name
            self.path = path
            self.slug = slug
            self.status = status
            self.message = message
            self.pullRequestRead = pullRequestRead
        }
    }

    /// The credential reference checked, as written in configuration (`keychain:github`).
    public var reference: String
    public var state: State
    /// The GitHub user the token belongs to, when it resolves.
    public var login: String?
    public var message: String
    public var repos: [Repo]

    public init(
        reference: String, state: State, login: String? = nil, message: String, repos: [Repo] = []
    ) {
        self.reference = reference
        self.state = state
        self.login = login
        self.message = message
        self.repos = repos
    }

    /// The credential resolves and every Repo can push (``RepoStatus/ok`` or ``RepoStatus/okUnverified``). A
    /// Repo's ``Repo/pullRequestRead`` plays no part.
    public var isValid: Bool {
        state == .resolves && repos.allSatisfy { $0.status == .ok || $0.status == .okUnverified }
    }

    /// The report in the last non-blank line of `lines`, decoded as a JSON object. Nil when there is no
    /// such line or it is not a report.
    public static func decodeLastLine(_ lines: [String]) -> Self? {
        guard let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return nil
        }
        return try? JSONDecoder().decode(Self.self, from: Data(last.utf8))
    }

    /// The report as one compact JSON object with sorted keys; `"{}"` if encoding fails.
    public func encodeLine() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
