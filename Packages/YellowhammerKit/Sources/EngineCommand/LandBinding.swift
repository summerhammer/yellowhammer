import Config
import Domain
import Engine
import Foundation
import Ledger
import GitHubAdapter
import Repositories

/// Wires the land Act's Repo Lane push (P10.2), pull request open (P10.4) and Verification (P10.5). The only place a GitHub
/// credential is resolved for landing (Engine never imports Config, ADR-001): the Project's Code Hosting
/// Connection is resolved through ``MachineConfiguration/codeHostingCredential(for:)``, and a refusal (a
/// connection absent from the registry) is thrown from the closure like a Keychain failure. A Keychain token
/// connection pushes with the token as an `http.extraHeader` and opens pull requests over URLSession. A `gh`
/// CLI connection holds no token: `gh` is found at the time of use (its declared path, else `PATH`), the push
/// uses `gh auth git-credential` as git's credential helper, and pull requests go through `gh api`; a `gh` that
/// is not found throws, which leaves the Cycle unlanded through the credentials-missing path.
/// The returned push and pull request closures resolve lazily, on each call, so a Rehearsal Night — which never
/// calls either seam — never touches the Keychain or `gh` for them (its mainline fetch resolves the connection
/// separately, through ``MainlineBinding``).
enum LandBinding {
    static func push(
        configuration: Configuration,
        project: ProjectConfiguration,
        credentials store: KeychainCredentialStore = KeychainCredentialStore(),
        gitHubCLI: @escaping @Sendable (String?) throws -> String = GitHubCLIExecutable.production
    ) -> FeatureBranchLanePush {
        FeatureBranchLanePush {
            try pushCredential(configuration: configuration, project: project, credentials: store, gitHubCLI: gitHubCLI)
        }
    }

    /// How the Project's Code Hosting Connection pushes: a Keychain token, or the `gh` CLI found now.
    static func pushCredential(
        configuration: Configuration, project: ProjectConfiguration, credentials store: KeychainCredentialStore,
        gitHubCLI: @Sendable (String?) throws -> String
    ) throws -> PushCredential {
        switch try configuration.machine.codeHostingCredential(for: project) {
        case .keychainToken(_, let reference):
            return .token(GitHubToken(try store.read(reference)))
        case .githubCLI(_, let executable):
            return .githubCLI(executable: try gitHubCLI(executable))
        }
    }

    /// The GitHub token the Project's Code Hosting Connection holds: the connection is resolved first, so a
    /// refusal is thrown before the Keychain is touched, and only that connection's reference is read.
    /// The token is nil for a `gh` CLI connection: `gh` authenticates, and the `gh` is found now so a missing
    /// one throws.
    static func token(
        configuration: Configuration, project: ProjectConfiguration, credentials store: KeychainCredentialStore,
        gitHubCLI: @Sendable (String?) throws -> String = GitHubCLIExecutable.production
    ) throws -> String? {
        switch try configuration.machine.codeHostingCredential(for: project) {
        case .keychainToken(_, let reference):
            return try store.read(reference)
        case .githubCLI(_, let executable):
            _ = try gitHubCLI(executable)
            return nil
        }
    }

    static func pullRequest(
        configuration: Configuration,
        project: ProjectConfiguration,
        credentials store: KeychainCredentialStore = KeychainCredentialStore(),
        scrub: @escaping @Sendable () -> NarrativeScrub = { .none },
        gitHubCLI: @escaping @Sendable (String?) throws -> String = GitHubCLIExecutable.production
    ) -> FeatureBranchPullRequest {
        // A refusal here is thrown again by the token closure on the first call.
        let transport: any GitHubTransport
        if case .githubCLI(_, let executable)? = try? configuration.machine.codeHostingCredential(for: project) {
            transport = GitHubCLILazyTransport(declared: executable, resolve: gitHubCLI)
        } else {
            transport = URLSessionGitHubTransport()
        }
        let adapter = GitHubAdapter(
            transport: transport,
            token: {
                try token(configuration: configuration, project: project, credentials: store, gitHubCLI: gitHubCLI)
            }
        )
        return FeatureBranchPullRequest(
            publication: adapter, titleTemplate: project.pullRequestTitle, changeType: project.changeType,
            projectID: project.id.rawValue, scrub: scrub
        )
    }

    /// Verification (P10.5): the same ``RoutingBinding`` resolver and Dispatch choice as the author Act —
    /// ``RehearsalDispatch`` in a rehearsal Night, ``CLIAdapterDispatch`` otherwise — with
    /// ``MainlineReader`` resolving each clause's Spec Citation.
    static func verification(
        mode: NightMode,
        configuration: Configuration,
        project: ProjectConfiguration,
        configurationDirectory: URL,
        refresher: MainlineRefresher,
        resultFixtures: RehearsalScript = RehearsalScript.empty
    ) throws -> FeatureVerification {
        let ledger = try LedgerStore.open(configurationDirectory: configurationDirectory)
        return FeatureVerification(
            resolver: try RoutingBinding.resolver(configuration: configuration, projectID: project.id, ledger: ledger),
            dispatch: DispatchBinding.dispatch(
                mode: mode, configuration: configuration, project: project,
                configurationDirectory: configurationDirectory, resultFixtures: resultFixtures
            ),
            citations: MainlineReader(refresher: refresher)
        )
    }
}

/// A ``GitHubTransport`` over `gh api` that finds `gh` on each send, so the executable is resolved at the time
/// of use and a missing one throws rather than being fixed when the land Act is wired.
private struct GitHubCLILazyTransport: GitHubTransport {
    let declared: String?
    let resolve: @Sendable (String?) throws -> String

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await GHCLITransport(executable: try resolve(declared)).send(request)
    }
}
