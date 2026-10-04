import Foundation

/// The `yh config` argument vectors the app runs for the Settings window's Linear workspaces list (L3.1):
/// the flag spelling lives here, next to `ConfigOperatorCommand` and `ConfigRemoveInstallationCommand`'s own
/// contract, so the app and the parsers can never drift apart.
public enum ConfigInvocation {
    /// `["config", "operator", "--installation", <installation>, <userID>]`: changes one App Installation's
    /// Operator identity. `--installation` is always passed, because the app always knows the row.
    public static func operatorArguments(installation: String, userID: String) -> [String] {
        ["config", "operator", "--installation", installation, userID]
    }

    /// `["config", "remove-installation", <name>]`: removes one App Installation from `config.toml` and
    /// deletes its Keychain items. With `orphanProjects`, `--orphan-projects --yes`: removes it even while
    /// Project files name it, once its authorization is permanently refused (OQ121); the app has already
    /// confirmed, so `--yes` skips the prompt.
    public static func removeInstallationArguments(name: String, orphanProjects: Bool = false) -> [String] {
        var arguments = ["config", "remove-installation", name]
        if orphanProjects { arguments += ["--orphan-projects", "--yes"] }
        return arguments
    }
}
