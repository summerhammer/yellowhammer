import Foundation

/// The `yh project` argument vectors the app runs for the Settings window's *Remove Project…* (the removal
/// itself is `ProjectRemoveCommand`'s): the spelling lives here, next to the parser's own contract, so the
/// app and the command can never drift apart.
public enum ProjectInvocation {
    /// `["project", "remove", <id>, "--yes"]`: removes one Project's machine-local footprint. The app has
    /// already confirmed, so `--yes` skips `yh`'s own prompt.
    public static func removeArguments(project: ProjectID) -> [String] {
        ["project", "remove", project.rawValue, "--yes"] // glossary:ignore GL001
    }
}
