import Config
import Domain
import Foundation
import GitHubAdapter
import Repositories
import Synchronization

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
    /// One HTTP exchange with GitHub through the GitHub CLI at the given executable (`gh api -i`), which
    /// authenticates as its active account. Tests drive a stub `gh` script through it.
    var sendViaGitHubCLI: @Sendable (String, URLRequest) async throws -> (Data, HTTPURLResponse) = {
        try await GHCLITransport(executable: $0).send($1)
    }
    /// A declared `gh` path, else `gh` found on the process's `PATH` and in the fixed directories; nil when
    /// there is none. Resolved at the time of use, on every report.
    var resolveGitHubCLI: @Sendable (String?) -> String? = { declared in
        GitHubCLIExecutable.resolve(
            declared: declared, path: ProcessInfo.processInfo.environment["PATH"],
            fileExists: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }

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
        reference: CredentialReference, secret: SecretLookup, repos: [(name: String, path: String)],
        connectionName: String? = nil
    ) async -> GitHubCredentialReport {
        let name = connectionName ?? Self.account(of: reference)
        let token: String
        switch secret {
        case .absent:
            return Self.unusable(reference, .missing, Self.missingMessage(reference, connectionName: name))
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
                    + "Replace it with `yh config replace-code-hosting-token \(name) --token-stdin`."
            )
        case .unavailable(let detail):
            return Self.unusable(
                reference, .unreachable, "The token in \(reference.rawValue) could not be checked: \(detail)."
            )
        case .authenticated(let login, let scopes):
            var results: [GitHubCredentialReport.Repo] = []
            for repo in repos {
                results.append(await repoResult(repo, token: token, holder: .token, scopes: scopes, check: check))
            }
            return GitHubCredentialReport(
                reference: reference.rawValue, state: .resolves, login: login,
                message: "The token in \(reference.rawValue) belongs to \(login).", repos: results
            )
        }
    }

    // MARK: GitHub CLI

    /// The verdict on the GitHub CLI and on each of `repos`: the same ``GitHubCredentialCheck`` as the Keychain
    /// path, run with no token over `gh api`, so `gh` authenticates as its active account. The report's
    /// `reference` is the literal `gh`. Nothing caches the login: every call runs `gh` again. Yellowhammer
    /// never runs anything that changes `gh`'s state.
    ///
    /// `executable` is the connection's declared `gh` path, or nil to look it up now. As for ``report``, pass
    /// only **working** Repos.
    func reportGitHubCLI(
        executable: String?, repos: [(name: String, path: String)], connectionName: String? = nil
    ) async -> GitHubCredentialReport {
        guard let path = resolveGitHubCLI(executable) else {
            return Self.gitHubCLIReport(.missing, GitHubCLIExecutable.notFoundMessage)
        }
        let failure = Mutex<String?>(nil)
        let check = GitHubCredentialCheck(transport: ClosureTransport { request in
            do {
                return try await sendViaGitHubCLI(path, request)
            } catch {
                // The check reports only an error's type; for gh the first line of its stderr is the news.
                if error is GHCLITransportError { failure.withLock { $0 = "\(error)" } }
                throw error
            }
        })
        switch await check.authenticate(token: nil) {
        case .rejected:
            return Self.gitHubCLIReport(
                .rejected,
                "gh is not logged in to github.com; run `gh auth login`. Yellowhammer never changes gh's login."
            )
        case .unavailable(let detail):
            let reason = failure.withLock { $0 } ?? detail
            return Self.gitHubCLIReport(.unreachable, "gh could not reach GitHub: \(reason).")
        case .authenticated(let login, let scopes):
            var results: [GitHubCredentialReport.Repo] = []
            for repo in repos {
                results.append(await repoResult(repo, token: nil, holder: .githubCLI, scopes: scopes, check: check))
            }
            return GitHubCredentialReport(
                reference: Self.gitHubCLIReference, state: .resolves, login: login,
                message: "The gh CLI (\(path)) acts as GitHub user \(login).", repos: results
            )
        }
    }

    /// The `reference` a report about the GitHub CLI carries: it holds no Keychain item, so no reference.
    static let gitHubCLIReference = "gh"

    private static func gitHubCLIReport(
        _ state: GitHubCredentialReport.State, _ message: String
    ) -> GitHubCredentialReport {
        GitHubCredentialReport(reference: gitHubCLIReference, state: state, message: message)
    }

    /// Who answers for the access the report describes, which words the per-Repo messages.
    private enum Holder {
        case token
        case githubCLI

        /// "the token can push" / "gh's active account can push".
        var subject: String { self == .token ? "the token" : "gh's active account" }
        /// "not accessible with this token" / "with gh's active account".
        var instrument: String { self == .token ? "this token" : "gh's active account" }
    }

    private func repoResult(
        _ repo: (name: String, path: String), token: String?, holder: Holder, scopes: [String]?,
        check: GitHubCredentialCheck
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
            (.ok, "\(label): \(holder.subject) can push.")
        case .canPushUnverifiedToken:
            (.okUnverified, "\(label): push is allowed for the GitHub user, but a fine-grained token's "
                + "Contents and Pull requests write access cannot be confirmed without writing.")
        case .noPushPermission:
            (.noPushPermission, "\(label): \(holder.subject) lacks push permission.")
        case .missingScope(let scope):
            (.missingScope, "\(label): \(holder.subject) lacks the \(scope) scope.")
        case .notFound:
            (.notFound, "\(label): not found or not accessible with \(holder.instrument).")
        case .rejected:
            (.rejected, "\(label): GitHub rejected \(holder.subject).")
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

    private static func missingMessage(_ reference: CredentialReference, connectionName: String) -> String {
        let account = account(of: reference)
        return "No GitHub token is stored for \(reference.rawValue): the Keychain has no item with service "
            + "\(KeychainCredentialStore.service) and account \(account). Store it with "
            + "`yh config replace-code-hosting-token \(connectionName) --token-stdin`."
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
