/// The one list of agent CLI names that have a CLI Adapter in code. `CLIAdapterRegistry` resolves each
/// of them to its adapter; the app reads this list because it cannot link `CLIAdapters`. Adding a new
/// kind of agent CLI is a code change — an adapter and an entry here — never configuration.
public enum RegisteredCLIAdapters {
    public static let names = ["claude", "codex", "agy"]

    /// The efforts each registered adapter accepts, least first: its `supportedEfforts`, restated for the
    /// app, which offers them when a Route is edited. `CLIAdapterRegistryTests` keeps the two equal.
    public static let supportedEfforts: [String: [String]] = [
        "claude": ["low", "medium", "high", "xhigh", "max"],
        "codex": ["minimal", "low", "medium", "high", "xhigh"],
        "agy": ["low", "medium", "high", "xhigh", "max"]
    ]
}
