import Config
import Domain
import Engine
import Foundation
import Synchronization

/// Builds the one ``NarrativeScrub`` every outbound narrative passes (OQ146/OQ147, R23): the only place
/// the credentials Yellowhammer holds are gathered for it (Engine never imports Config, ADR-001). It is
/// a floor, not a guarantee — it matches held credentials by value and keeps no secret-pattern list.
enum NarrativeScrubBinding {
    /// A closure that builds the scrub on each call.
    ///
    /// The Board Connection's token pair is read fresh each call, so a token refreshed mid-Act is still
    /// matched; any read failure contributes nothing and never throws. The GitHub credential is read only
    /// when `mode` is `.real`, lazily on the first call, and then held: a failed read contributes nothing
    /// and is not retried, and a Rehearsal Night never touches the GitHub Keychain item.
    static func source(
        mode: NightMode,
        configuration: Configuration,
        project: ProjectConfiguration,
        credentials: KeychainCredentialStore = KeychainCredentialStore(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> @Sendable () -> NarrativeScrub {
        let installation = configuration.machine.linearInstallation(for: project)
        let gitHub = HeldCredential {
            let reference = configuration.machine.gitHubCredential(for: project)
            return try? credentials.read(reference)
        }
        let roots = project.repositories.workingRepos.map { ($0.path as NSString).expandingTildeInPath }
        let home = homeDirectory.path
        return {
            var held: [String] = []
            if let installation {
                let store = BoardBinding.installationStore(
                    for: installation, credentials: credentials, homeDirectory: homeDirectory
                ).tokenStore
                if let pair = try? store.read() {
                    held += [pair.accessToken, pair.refreshToken]
                }
            }
            if mode == .real, let token = gitHub.value() {
                held.append(token)
            }
            return NarrativeScrub(credentials: held, homeDirectory: home, repositoryRoots: roots)
        }
    }
}

/// A credential read at most once, on first use, and held for the process's life — success or not.
private final class HeldCredential: Sendable {
    private let load: @Sendable () -> String?
    private let state = Mutex<String??>(nil)

    init(load: @escaping @Sendable () -> String?) {
        self.load = load
    }

    func value() -> String? {
        state.withLock { state in
            if let loaded = state { return loaded }
            let loaded = load()
            state = .some(loaded)
            return loaded
        }
    }
}
