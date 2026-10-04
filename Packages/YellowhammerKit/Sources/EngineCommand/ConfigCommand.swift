import ArgumentParser

/// `yh config`: a command group for machine-wide configuration edits that are not Setup. Two
/// subcommands: `operator` (change one App Installation's Operator identity) and `remove-installation`
/// (spec `install-the-linear-app`, *Removing an installation*; OQ66; OQ109 items 7, 8 and 14; OQ116).
/// `remove-installation --orphan-projects` (OQ121) is the one override of its refusal while Projects name
/// the installation, gated on the installation's authorization being permanently refused.
public struct ConfigCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Machine-wide configuration edits.",
        subcommands: [ConfigOperatorCommand.self, ConfigRemoveInstallationCommand.self],
        defaultSubcommand: nil
    )

    public init() {}
}
