import ArgumentParser

/// `yh config`: a command group for machine-wide configuration edits that are not Setup. Two
/// subcommands: `operator` (change one App Installation's Operator identity) and `remove-installation`
/// (spec `install-the-linear-app`, *Removing an installation*; OQ66; OQ109 items 7, 8 and 14; OQ116).
public struct ConfigCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Machine-wide configuration edits.",
        subcommands: [ConfigOperatorCommand.self, ConfigRemoveInstallationCommand.self],
        defaultSubcommand: nil
    )

    public init() {}
}
