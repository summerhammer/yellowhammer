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
    ///
    /// With `readsPullRequests` (`yh doctor`'s Check 5 only), each GitHub Repo also gets a pull request read
    /// check: one real read through the Publication Port's read, with the same transport and token.
    func report(
        reference: CredentialReference, secret: SecretLookup, repos: [(name: String, path: String)],
        connectionName: String? = nil, readsPullRequests: Bool = false
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

        let transport = ClosureTransport(exchange: send)
        let check = GitHubCredentialCheck(transport: transport)
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
            let reader = readsPullRequests ? GitHubAdapter(transport: transport, token: { token }) : nil
            var results: [GitHubCredentialReport.Repo] = []
            for repo in repos {
                let asker = Asker(token: token, holder: .token, scopes: scopes, check: check, reader: reader)
                results.append(await repoResult(repo, asker: asker))
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
    /// only **working** Repos; `readsPullRequests` adds the same pull request read check, over `gh api`.
    func reportGitHubCLI(
        executable: String?, repos: [(name: String, path: String)], connectionName: String? = nil,
        readsPullRequests: Bool = false
    ) async -> GitHubCredentialReport {
        guard let path = resolveGitHubCLI(executable) else {
            return Self.gitHubCLIReport(.missing, GitHubCLIExecutable.notFoundMessage)
        }
        let cliFailure = Mutex<GHCLITransportError?>(nil)
        let transport = ClosureTransport { request in
            do {
                return try await sendViaGitHubCLI(path, request)
            } catch let error as GHCLITransportError {
                cliFailure.withLock { $0 = error }
                throw error
            }
        }
        let check = GitHubCredentialCheck(transport: transport)
        switch await check.authenticate(token: nil) {
        case .rejected:
            let failure = cliFailure.withLock { $0 }
            return Self.gitHubCLIReport(.rejected, Self.gitHubCLIAuthenticationMessage(failure))
        case .unavailable(let detail):
            let reason = cliFailure.withLock { $0 }.map { String(describing: $0) } ?? detail
            return Self.gitHubCLIReport(.unreachable, "gh could not reach GitHub: \(reason).")
        case .authenticated(let login, let scopes):
            let reader = readsPullRequests ? GitHubAdapter(transport: transport, token: { nil }) : nil
            var results: [GitHubCredentialReport.Repo] = []
            for repo in repos {
                let asker = Asker(token: nil, holder: .githubCLI, scopes: scopes, check: check, reader: reader)
                results.append(await repoResult(repo, asker: asker))
            }
            return GitHubCredentialReport(
                reference: Self.gitHubCLIReference, state: .resolves, login: login,
                message: "The gh CLI (\(path)) acts as GitHub user \(login).", repos: results
            )
        }
    }

    /// The `reference` a report about the GitHub CLI carries: it holds no Keychain item, so no reference.
    static let gitHubCLIReference = "gh"

    private static func gitHubCLIAuthenticationMessage(_ error: GHCLITransportError?) -> String {
        let suffix = " Yellowhammer never changes gh's login."
        guard case .authenticationFailed(let exitCode, let statusCode, let detail) = error else {
            return "GitHub refused the gh token (HTTP 401). Check `gh auth status`, refresh the gh "
                + "authentication as needed, then retry." + suffix
        }
        let evidence = detail.isEmpty ? "" : " (\(detail))"
        if let statusCode {
            return "GitHub refused the gh token (HTTP \(statusCode), gh exit \(exitCode))\(evidence). "
                + "Check `gh auth status`, refresh the gh authentication as needed, then retry." + suffix
        }
        return "gh found no credentials for github.com (gh exit \(exitCode))\(evidence). "
            + "Check `gh auth status` and retry; if gh has no active login, run `gh auth login`." + suffix
    }

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

    /// What asks GitHub about each Repo once the credential authenticated.
    private struct Asker {
        /// Nil when the transport authenticates (`gh`).
        let token: String?
        let holder: Holder
        let scopes: [String]?
        let check: GitHubCredentialCheck
        /// The Publication Port's read over the same transport and token; nil when no read check is asked.
        let reader: GitHubAdapter?
    }

    private func repoResult(
        _ repo: (name: String, path: String), asker: Asker
    ) async -> GitHubCredentialReport.Repo {
        let holder = asker.holder
        guard let slug = await resolveSlug(repo.path) else {
            return GitHubCredentialReport.Repo(
                name: repo.name, path: repo.path, status: .notGitHub,
                message: "Repo \(repo.name): its origin remote is not a GitHub repository, so no pull request "
                    + "can be opened for it."
            )
        }
        let name = "\(slug.owner)/\(slug.repository)"
        let access = await asker.check.access(
            token: asker.token, owner: slug.owner, repository: slug.repository, scopes: asker.scopes
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
        let read = if let reader = asker.reader {
            await Self.pullRequestRead(slug, label: label, holder: holder, reader: reader)
        } else {
            GitHubCredentialReport.PullRequestRead?.none
        }
        return GitHubCredentialReport.Repo(
            name: repo.name, path: repo.path, slug: name, status: status, message: message, pullRequestRead: read
        )
    }

    /// The head branch the pull request read check lists pull requests for. No Feature Branch is named so
    /// (theirs start `yh-`), so the read answers an empty list; listing it still needs read access to the
    /// repository's pull requests, which is what is checked — never inferred from the token's scopes.
    static let readCheckBranch = "yellowhammer/doctor-read-check"

    /// One pull request read through the Publication Port's read (OQ190 item 29: the same credential, adapter
    /// and transport as the push). GitHub refusing it (no access, or the credential refused) is "cannot read";
    /// GitHub giving no verdict (unreachable, rate limited, an unreadable answer) is "unverified".
    private static func pullRequestRead(
        _ slug: GitHubRepositorySlug, label: String, holder: Holder, reader: GitHubAdapter
    ) async -> GitHubCredentialReport.PullRequestRead {
        let query = PullRequestQuery(
            owner: slug.owner, repository: slug.repository, selector: .headBranch(readCheckBranch)
        )
        do throws(PullRequestReadFailure) {
            _ = try await reader.readPullRequests(query)
            return .init(status: .canRead, message: "\(label): \(holder.subject) can read pull requests.")
        } catch {
            switch error.reason {
            case .noAccess, .credentialRefused:
                return .init(
                    status: .cannotRead,
                    message: "\(label): \(holder.subject) cannot read pull requests (\(error.detail)), so a merge "
                        + "is observed only by ancestry or content."
                )
            case .unreachable, .rateLimited, .unreadableAnswer:
                return .init(
                    status: .unverified,
                    message: "\(label): whether \(holder.subject) can read pull requests is unverified: "
                        + "\(error.reason.words) (\(error.detail))."
                )
            }
        }
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
