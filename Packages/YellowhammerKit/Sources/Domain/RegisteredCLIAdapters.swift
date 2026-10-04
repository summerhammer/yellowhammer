/// The one list of agent CLI names that have a CLI Adapter in code. `CLIAdapterRegistry` resolves each
/// of them to its adapter; the app reads this list because it cannot link `CLIAdapters`. Adding a new
/// kind of agent CLI is a code change — an adapter and an entry here — never configuration.
public enum RegisteredCLIAdapters {
    public static let names = ["claude", "codex", "agy"]
}
