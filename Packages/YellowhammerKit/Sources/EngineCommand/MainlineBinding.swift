import Config
import Domain
import Foundation
import Ledger
import Repositories

/// Wires the Act-start mainline fetch (OQ152). The fetch authenticates with the Project's Code Hosting
/// Connection, resolved through ``LandBinding/pushCredential(configuration:project:credentials:gitHubCLI:)``
/// (the same credential the land push uses) and never falls back to ambient git credentials. Resolution is
/// lazy, inside the closure, and the refresher resolves it once per refresh. A Rehearsal Night fetches too, so
/// it resolves the connection like any other Night.
enum MainlineBinding {
    static func mainlineRefresher(
        configuration: Configuration,
        project: ProjectConfiguration,
        credentials store: KeychainCredentialStore = KeychainCredentialStore(),
        gitHubCLI: @escaping @Sendable (String?) throws -> String = GitHubCLIExecutable.production
    ) -> MainlineRefresher {
        MainlineRefresher(
            credential: credential(
                configuration: configuration, project: project, credentials: store, gitHubCLI: gitHubCLI
            )
        )
    }

    /// The refresher's credential seam: resolves the Project's connection on each call, and throws a refusal.
    static func credential(
        configuration: Configuration,
        project: ProjectConfiguration,
        credentials store: KeychainCredentialStore,
        gitHubCLI: @escaping @Sendable (String?) throws -> String
    ) -> @Sendable () throws -> PushCredential? {
        {
            try LandBinding.pushCredential(
                configuration: configuration, project: project, credentials: store, gitHubCLI: gitHubCLI
            )
        }
    }
}
