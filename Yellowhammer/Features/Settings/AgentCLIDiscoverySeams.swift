import Config
import Foundation

/// What the Agent CLIs pane's discovery reads. Production reads the Operator's real login shell, PATH and
/// `/etc`; under a UI test (a configuration directory override) it never touches the real machine and spawns
/// no shell.
enum AgentCLIDiscoverySeams {
    /// The environment to search, and why the login shell could not be read, if it could not.
    static func environment(
        directory: URL
    ) async -> (environment: CLIDiscoveryEnvironment, loginShellFailure: String?) {
        if ConfigurationDirectory.isOverridden {
            let home = ConfigurationDirectory.discoveryHomePath ?? directory.path(percentEncoded: false)
            return (
                CLIDiscoveryEnvironment(
                    homeDirectory: home, processPATH: nil, loginShellPATH: nil, etcDirectory: home + "/etc"
                ),
                nil
            )
        }
        var failure: String?
        var loginPATH: String?
        switch await LoginShellPATH.read() {
        case .path(let path): loginPATH = path
        case .failed(let reason): failure = reason.description
        }
        return (
            CLIDiscoveryEnvironment(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false),
                processPATH: ProcessInfo.processInfo.environment["PATH"],
                loginShellPATH: loginPATH,
                etcDirectory: "/etc"
            ),
            failure
        )
    }
}
