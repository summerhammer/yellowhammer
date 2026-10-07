import Foundation

/// What discovery knows about one vendor's agent CLI: the data, kept apart from the mechanism that uses it.
public struct AgentCLIDescriptor: Sendable {
    /// The name the Routing Table and `[cli.<name>]` use: `claude`.
    public let cli: String
    /// The vendor's name for the product, in words for the Operator: `Claude Code`.
    public let vendorName: String
    /// The file names the CLI is installed as: `["claude"]`.
    public let executableNames: [String]
    /// Directories this CLI is installed in beyond the common ones, searched before them.
    public let locations: [CLISearchLocation]
    /// Why the file at `path` (really `resolvedPath`) is not this CLI, in a sentence for the Operator; nil when
    /// nothing is known against it.
    public let refusal: @Sendable (_ path: String, _ resolvedPath: String) -> String?

    public init(
        cli: String,
        vendorName: String,
        executableNames: [String],
        locations: [CLISearchLocation] = [],
        refusal: @escaping @Sendable (_ path: String, _ resolvedPath: String) -> String? = { _, _ in nil }
    ) {
        self.cli = cli
        self.vendorName = vendorName
        self.executableNames = executableNames
        self.locations = locations
        self.refusal = refusal
    }
}

/// The agent CLIs discovery looks for, and the directories it looks in besides `PATH`.
///
/// Adding a CLI to discovery is one entry in ``all``. Discovery is not support: a descriptor whose `cli` has no
/// adapter in `RegisteredCLIAdapters` is reported as detected but unsupported.
public enum AgentCLIDescriptors {
    public static let all: [AgentCLIDescriptor] = [
        AgentCLIDescriptor(
            cli: "claude", vendorName: "Claude Code", executableNames: ["claude"],
            locations: [.home(".claude/local")]
        ),
        AgentCLIDescriptor(cli: "codex", vendorName: "Codex", executableNames: ["codex"]),
        AgentCLIDescriptor(
            cli: "agy", vendorName: "Antigravity", executableNames: ["agy"],
            refusal: { _, resolvedPath in
                // The editor's launcher shares the name. The CLI is a standalone binary (~/.local/bin/agy or
                // $HOMEBREW_PREFIX/bin/agy); an installed app proves nothing.
                guard resolvedPath.contains(".app/Contents/") else { return nil }
                return "\(resolvedPath) is an editor launcher inside an app bundle, not the Antigravity CLI "
                    + "(agy)."
            }
        )
    ]

    /// Directories searched for every CLI after the `PATH` and the CLI's own locations: user-local, Homebrew,
    /// package managers, version-manager version directories (newest first), and version-manager shims last.
    public static let commonLocations: [CLISearchLocation] = [
        .home(".local/bin"),
        .absolute("/opt/homebrew/bin"),
        .absolute("/usr/local/bin"),
        .home(".npm-global/bin"),
        .home(".bun/bin"),
        .home(".volta/bin"),
        .home("Library/pnpm/bin"),
        .home("Library/pnpm"),
        .home(".yarn/bin"),
        .versions(parent: ".nvm/versions/node", suffix: "bin"),
        .versions(parent: ".local/share/fnm/node-versions", suffix: "installation/bin"),
        .versions(parent: "Library/Application Support/fnm/node-versions", suffix: "installation/bin"),
        .versions(parent: ".local/share/mise/installs/node", suffix: "bin"),
        .home(".asdf/shims"),
        .home(".local/share/mise/shims")
    ]
}
