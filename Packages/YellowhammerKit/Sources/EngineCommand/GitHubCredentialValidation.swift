import Config
import Domain
import Foundation
import GitHubAdapter
import Repositories

/// Checks a GitHub credential against GitHub and the Repos it must publish: shared by `yh doctor` and
/// `yh setup`, so both say the same thing. Read-only — it never writes to GitHub, and the token appears in
/// no report.
///
/// Holds the transport as a plain closure (as the Linear install flow does) so tests drive the real
/// ``GitHubCredentialCheck`` without importing the adapter (MB2).
struct GitHubCredentialValidation: Sendable {
    /// The Keychain lookup of the credential's token, as the caller found it.
    enum SecretLookup: Sendable {
        case present(String)
        case absent
        /// The item may exist but could not be read (a locked Keychain); the message is the read error.
        case unreadable(String)
    }

    /// One HTTP exchange with GitHub.
    let send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    /// A Repo path's GitHub slug, read from its `origin` remote; nil when it is not a GitHub repository.
    let resolveSlug: @Sendable (String) async -> GitHubRepositorySlug?

    static func production() -> Self {
        let transport = URLSessionGitHubTransport()
        let resolver = GitHubRepositorySlugResolver()
        return Self(
            send: { try await transport.send($0) },
            resolveSlug: { await resolver.resolve(path: $0) }
        )
    }

    /// The verdict on `reference` and on each of `repos`.
    ///
    /// Pass only **working** Repos: the caller filters out a Repo whose role is ``RepoRole/spec`` (and a
    /// Project's Spec Source) because the Spec Source is read-only — nothing is ever pushed to it, so its
    /// access is not the credential's business.
    func report(
        reference: CredentialReference, secret: SecretLookup, repos: [(name: String, path: String)]
    ) async -> GitHubCredentialReport {
        let token: String
        switch secret {
        case .absent:
            return Self.unusable(reference, .missing, Self.missingMessage(reference))
        case .unreadable(let detail):
            return Self.unusable(
                reference, .unreadable,
                "The Keychain item for \(reference.rawValue) could not be read (\(detail)); "
                    + "unlock the login Keychain and check again."
            )
        case .present(let value):
            token = value
        }

        let check = GitHubCredentialCheck(transport: ClosureTransport(exchange: send))
        switch await check.authenticate(token: token) {
        case .rejected:
            return Self.unusable(
                reference, .rejected,
                "GitHub rejected the token in \(reference.rawValue): it is wrong, revoked or expired. "
                    + "Replace it with `yh setup --install-github`, or Settings › General › Replace token…."
            )
        case .unavailable(let detail):
            return Self.unusable(
                reference, .unreachable, "The token in \(reference.rawValue) could not be checked: \(detail)."
            )
        case .authenticated(let login, let scopes):
            var results: [GitHubCredentialReport.Repo] = []
            for repo in repos {
                results.append(await repoResult(repo, token: token, scopes: scopes, check: check))
            }
            return GitHubCredentialReport(
                reference: reference.rawValue, state: .resolves, login: login,
                message: "The token in \(reference.rawValue) belongs to \(login).", repos: results
            )
        }
    }

    private func repoResult(
        _ repo: (name: String, path: String), token: String, scopes: [String]?, check: GitHubCredentialCheck
    ) async -> GitHubCredentialReport.Repo {
        guard let slug = await resolveSlug(repo.path) else {
            return GitHubCredentialReport.Repo(
                name: repo.name, path: repo.path, status: .notGitHub,
                message: "Repo \(repo.name): its origin remote is not a GitHub repository, so no pull request "
                    + "can be opened for it."
            )
        }
        let name = "\(slug.owner)/\(slug.repository)"
        let access = await check.access(
            token: token, owner: slug.owner, repository: slug.repository, scopes: scopes
        )
        let label = "Repo \(repo.name) (\(name))"
        let (status, message): (GitHubCredentialReport.RepoStatus, String) = switch access {
        case .canPush:
            (.ok, "\(label): the token can push.")
        case .canPushUnverifiedToken:
            (.okUnverified, "\(label): push is allowed for the GitHub user, but a fine-grained token's "
                + "Contents and Pull requests write access cannot be confirmed without writing.")
        case .noPushPermission:
            (.noPushPermission, "\(label): the token lacks push permission.")
        case .missingScope(let scope):
            (.missingScope, "\(label): the token lacks the \(scope) scope.")
        case .notFound:
            (.notFound, "\(label): not found or not accessible with this token.")
        case .rejected:
            (.rejected, "\(label): GitHub rejected the token.")
        case .unavailable(let detail):
            (.unreachable, "\(label): could not be checked: \(detail).")
        }
        return GitHubCredentialReport.Repo(
            name: repo.name, path: repo.path, slug: name, status: status, message: message
        )
    }

    private static func unusable(
        _ reference: CredentialReference, _ state: GitHubCredentialReport.State, _ message: String
    ) -> GitHubCredentialReport {
        GitHubCredentialReport(reference: reference.rawValue, state: state, message: message)
    }

    /// The Keychain account behind `reference`: the reference without its `keychain:` scheme.
    static func account(of reference: CredentialReference) -> String {
        reference.rawValue.hasPrefix("keychain:")
            ? String(reference.rawValue.dropFirst("keychain:".count)) : reference.rawValue
    }

    private static func missingMessage(_ reference: CredentialReference) -> String {
        let account = account(of: reference)
        return "No GitHub token is stored for \(reference.rawValue): the Keychain has no item with service "
            + "\(KeychainCredentialStore.service) and account \(account). Store it with "
            + "`yh setup --install-github`, or Settings › General › Replace token…."
    }
}

extension SetupCredentialStore {
    /// One read of the Keychain item behind `reference`, telling a miss from a locked Keychain by asking for
    /// presence. Shared by `yh doctor` and `yh setup`.
    func gitHubSecret(for reference: CredentialReference) -> GitHubCredentialValidation.SecretLookup {
        if let token = secret(for: reference) { return .present(token) }
        switch presence(of: reference) {
        case .absent: return .absent
        case .unreadable(let detail): return .unreadable(detail)
        case .present: return .unreadable("the item could not be read")
        }
    }
}

/// Adapts the closure to the adapter's `GitHubTransport` seam.
private struct ClosureTransport: GitHubTransport {
    let exchange: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await exchange(request)
    }
}
