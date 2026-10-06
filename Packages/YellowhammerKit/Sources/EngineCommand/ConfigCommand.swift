import ArgumentParser

/// `yh config`: a command group for machine-wide configuration edits that are not Setup. Two
/// subcommands: `operator` (change one Board Connection's Operator identity) and `remove-board-connection`
/// (spec `install-the-linear-app`, *Removing a connection*; OQ66; OQ109 items 7, 8 and 14; OQ116).
/// `remove-board-connection --orphan-projects` (OQ121) is the one override of its refusal while Projects name
/// the connection, gated on the connection's authorization being permanently refused.
public struct ConfigCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Machine-wide configuration edits.",
        subcommands: [ConfigOperatorCommand.self, ConfigRemoveBoardConnectionCommand.self],
        defaultSubcommand: nil
    )

    public init() {}
}
