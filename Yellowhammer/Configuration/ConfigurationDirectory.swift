import Config
import Foundation

/// Where the app reads Yellowhammer's configuration from: the real one, or a UI test's fixture
/// directory. Shared by ``ConfiguredProjects`` and the Setup wizard, so they can never disagree about
/// which `config.toml` is "the" one, and so the wizard can tell whether one already exists.
enum ConfigurationDirectory {
    /// The launch argument that points the app at another configuration directory, for UI tests
    /// (`-YellowhammerConfigurationDirectory <path>`). Only the argument domain is read, so it cannot
    /// persist through `defaults write`.
    static let argument = "YellowhammerConfigurationDirectory"

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

    /// Whether `config.toml` already exists in `directory`: the Setup wizard's Linear step keeps it
    /// rather than asking for the client id and credential references again.
    static func machineFileExists(in directory: URL) -> Bool {
        let url = directory.appending(component: "config.toml", directoryHint: .notDirectory)
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
}
