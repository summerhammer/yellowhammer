import Foundation

/// The `yh config` argument vectors the app runs for the Settings window's Board connections list (L3.1):
/// the flag spelling lives here, next to `ConfigOperatorCommand` and `ConfigRemoveBoardConnectionCommand`'s own
/// contract, so the app and the parsers can never drift apart.
public enum ConfigInvocation {
    /// `["config", "operator", "--board-connection", <boardConnection>, <userID>]`: changes one Board Connection's
    /// Operator identity. `--board-connection` is always passed, because the app always knows the row.
    public static func operatorArguments(boardConnection: String, userID: String) -> [String] {
        ["config", "operator", "--board-connection", boardConnection, userID]
    }

    /// `["config", "remove-board-connection", <name>]`: removes one Board Connection from `config.toml` and
    /// deletes its Keychain items. With `orphanProjects`, `--orphan-projects --yes`: removes it even while
    /// Project files name it, once its authorization is permanently refused (OQ121); the app has already
    /// confirmed, so `--yes` skips the prompt.
    public static func removeBoardConnectionArguments(name: String, orphanProjects: Bool = false) -> [String] {
        var arguments = ["config", "remove-board-connection", name]
        if orphanProjects { arguments += ["--orphan-projects", "--yes"] }
        return arguments
    }
}
