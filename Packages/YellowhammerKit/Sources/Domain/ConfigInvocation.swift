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
    /// deletes its Keychain items.
    public static func removeInstallationArguments(name: String) -> [String] {
        ["config", "remove-installation", name]
    }
}
