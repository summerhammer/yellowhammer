import ArgumentParser

/// `yh project`: a command group for Project-scoped operations that are not Acts. Currently one
/// subcommand, `remove` (roadmap P13.5; spec risks.md OQ52(1)).
public struct ProjectCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "project",
        abstract: "Project-scoped operations.",
        subcommands: [ProjectRemoveCommand.self],
        defaultSubcommand: nil
    )

    public init() {}
}
