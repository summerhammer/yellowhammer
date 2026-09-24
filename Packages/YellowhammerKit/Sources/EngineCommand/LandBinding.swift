import Config
import Domain
import Engine
import Foundation
import Ledger
import GitHubAdapter
import Repositories

/// Wires the land Act's Repo Lane push (P10.2), pull request open (P10.4) and Verification (P10.5). The only place a GitHub
/// credential is resolved for landing (Engine never imports Config, ADR-001): the returned closure
/// reads the Keychain lazily, on each call, so a Rehearsal Night — which never calls either seam —
/// never touches the Keychain.
enum LandBinding {
    static func push(
        configuration: Configuration,
        project: ProjectConfiguration,
        credentials store: KeychainCredentialStore = KeychainCredentialStore()
    ) -> FeatureBranchLanePush {
        FeatureBranchLanePush {
            let reference = configuration.machine.gitHubCredential(for: project)
            let secret = try store.read(reference)
            return GitHubToken(secret)
        }
    }

    static func pullRequest(
        configuration: Configuration,
        project: ProjectConfiguration,
        credentials store: KeychainCredentialStore = KeychainCredentialStore()
    ) -> FeatureBranchPullRequest {
        let adapter = GitHubAdapter {
            let reference = configuration.machine.gitHubCredential(for: project)
            return try store.read(reference)
        }
        return FeatureBranchPullRequest(publication: adapter)
    }

    /// Verification (P10.5): the same ``RoutingBinding`` resolver and Dispatch choice as the author Act —
    /// ``RehearsalDispatch`` in a rehearsal Night, ``CLIAdapterDispatch`` otherwise — with
    /// ``MainlineReader`` resolving each clause's Spec Citation.
    static func verification(
        mode: NightMode,
        configuration: Configuration,
        project: ProjectConfiguration,
        configurationDirectory: URL,
        resultFixtures: [RunPass: RehearsalResultFixture] = [:]
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
