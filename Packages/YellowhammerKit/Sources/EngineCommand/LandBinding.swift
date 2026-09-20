import Config
import Engine
import Repositories

/// Wires the land Act's Repo Lane push (P10.2). The only place a GitHub credential is resolved for
/// landing (Engine never imports Config, ADR-001): the returned closure reads the Keychain lazily, on
/// each call, so a Rehearsal Night — which never calls the push seam — never touches the Keychain.
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
}
