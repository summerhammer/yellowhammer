import Foundation

/// What checking the GitHub credential found: the single shared shape the engine encodes (one compact JSON
/// object on the command's last line) and the app decodes, so the two can never drift. The raw values of
/// ``State`` and ``RepoStatus`` are a contract with the app.
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

    /// One working Repo's verdict.
    public struct Repo: Codable, Equatable, Sendable {
        public var name: String
        public var path: String
        /// `owner/name`, when the Repo's `origin` named a GitHub repository.
        public var slug: String?
        public var status: RepoStatus
        public var message: String

        public init(name: String, path: String, slug: String? = nil, status: RepoStatus, message: String) {
            self.name = name
            self.path = path
            self.slug = slug
            self.status = status
            self.message = message
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

    /// The credential resolves and every Repo can push (``RepoStatus/ok`` or ``RepoStatus/okUnverified``).
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
