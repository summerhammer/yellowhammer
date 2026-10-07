import Config
import Foundation

/// Where the app reads Yellowhammer's configuration from: the real one, or a UI test's fixture
/// directory. Shared by ``ConfiguredProjects`` and the Add Project sheet, so they can never disagree about
/// which `config.toml` is "the" one.
enum ConfigurationDirectory {
    /// The launch argument that points the app at another configuration directory, for UI tests
    /// (`-YellowhammerConfigurationDirectory <path>`). Only the argument domain is read, so it cannot
    /// persist through `defaults write`.
    static let argument = "YellowhammerConfigurationDirectory"

    /// The launch argument that gives the Agent CLIs pane's discovery a fixture home directory under a UI test
    /// (`-YellowhammerDiscoveryHome <path>`), so it never reads the real machine. Only the argument domain is
    /// read, and only while ``isOverridden``.
    static let discoveryHomeArgument = "YellowhammerDiscoveryHome"

    /// The fixture home directory for discovery, nil when no UI test gave one.
    static var discoveryHomePath: String? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[discoveryHomeArgument] as? String
    }

    /// Whether the app is pointed at another configuration directory than the one `yh` reads.
    static var isOverridden: Bool { overridePath != nil }

    private static var overridePath: String? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)[argument] as? String
    }

    static var current: URL {
        if let path = overridePath {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return Configuration.defaultDirectoryURL(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }
}
