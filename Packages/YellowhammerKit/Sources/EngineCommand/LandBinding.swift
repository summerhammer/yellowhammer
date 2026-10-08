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
/// connection absent from the registry, or a `gh` CLI one) is thrown from the closure like a Keychain failure.
/// The returned closure reads the Keychain lazily, on each call, so a Rehearsal Night — which never calls either seam —
/// never touches the Keychain.
enum LandBinding {
    static func push(
        configuration: Configuration,
        project: ProjectConfiguration,
        credentials store: KeychainCredentialStore = KeychainCredentialStore()
    ) -> FeatureBranchLanePush {
        FeatureBranchLanePush {
            GitHubToken(try token(configuration: configuration, project: project, credentials: store))
        }
    }

    /// The GitHub token the Project's Code Hosting Connection holds: the connection is resolved first, so a
    /// refusal is thrown before the Keychain is touched, and only that connection's reference is read.
    static func token(
        configuration: Configuration, project: ProjectConfiguration, credentials store: KeychainCredentialStore
    ) throws -> String {
        let credential = try configuration.machine.codeHostingCredential(for: project)
        return try store.read(credential.reference)
    }

    static func pullRequest(
        configuration: Configuration,
        project: ProjectConfiguration,
        credentials store: KeychainCredentialStore = KeychainCredentialStore(),
        scrub: @escaping @Sendable () -> NarrativeScrub = { .none }
    ) -> FeatureBranchPullRequest {
        let adapter = GitHubAdapter {
            try token(configuration: configuration, project: project, credentials: store)
        }
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
        resultFixtures: RehearsalScript = RehearsalScript.empty
    ) throws -> FeatureVerification {
        let ledger = try LedgerStore.open(configurationDirectory: configurationDirectory)
        return FeatureVerification(
            resolver: try RoutingBinding.resolver(configuration: configuration, projectID: project.id, ledger: ledger),
            dispatch: DispatchBinding.dispatch(
                mode: mode, configuration: configuration, project: project,
                configurationDirectory: configurationDirectory, resultFixtures: resultFixtures
            ),
            citations: MainlineReader()
        )
    }
}
