/// Looks up the ``CLIAdapter`` for a Routing Table `cli` name, so a name with no adapter is refused
/// explicitly rather than failing deep inside a launch.
public enum CLIAdapterRegistry {
    public static func adapter(named name: String) -> (any CLIAdapter)? {
        switch name {
        case "claude": ClaudeCodeAdapter()
        case "codex": CodexAdapter()
        default: nil
        }
    }
}
