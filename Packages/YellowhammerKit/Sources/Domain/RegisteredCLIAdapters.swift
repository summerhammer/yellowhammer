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

    /// The effort an `agy` model id already encodes in its `-<effort>` suffix (`gemini-4-argon-medium` →
    /// `medium`), when that differs from the Route's own effort. agy refuses the pair at argument parsing
    /// (`--model gemini-4-argon-medium conflicts with --effort=high`) before it starts a session, so the
    /// conflict must be caught at config load and at launch build, not mid-Night (issue #649). Nil for
    /// another CLI, an unsuffixed model, or a suffix that matches the effort.
    public static func conflictingEffortSuffix(in route: Route) -> String? {
        guard route.cli == "agy" else { return nil }
        let suffix = supportedEfforts["agy", default: []].first { route.model.hasSuffix("-\($0)") }
        guard let suffix, suffix != route.effort else { return nil }
        return suffix
    }
}
