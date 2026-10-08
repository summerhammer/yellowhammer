import ArgumentParser

/// `yh project`: a command group for Project-scoped operations that are not Acts. Subcommands:
/// `remove` (roadmap P13.5; spec risks.md OQ52(1)) and `set-code-hosting-connection` (roadmap S3, #389).
public struct ProjectCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "project",
        abstract: "Project-scoped operations.",
        subcommands: [ProjectRemoveCommand.self, ProjectSetCodeHostingConnectionCommand.self],
        defaultSubcommand: nil
    )

    public init() {}
}
