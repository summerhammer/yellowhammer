import ArgumentParser

extension SetupOptions {
    /// `--install-cli` and `--uninstall-cli` are standalone modes exclusive with everything that generates,
    /// adopts or provisions configuration.
    static func validateStandaloneCLIMode(_ command: SetupCommand, flag: String) throws {
        let forbidden: [(Bool, String)] = [
            (command.initialize, "--init"),
            (command.config != nil, "--config"),
            (command.printChoices, "--print-choices"),
            (command.installLinear, "--install-linear"),
            (command.installJobs, "--install-jobs"),
            (command.exportJobs != nil, "--export-jobs"),
            (command.cron, "--cron"),
            (command.project != nil, "--project"), // glossary:ignore GL001
            (command.projectName != nil, "--project-name"), // glossary:ignore GL001
            (command.linearProject != nil, "--linear-project"), // glossary:ignore GL001
            (command.linearTeam != nil, "--linear-team"),
            (command.specSource != nil, "--spec-source"),
            (command.nightStart != nil, "--night-start"),
            (command.nightEnd != nil, "--night-end"),
            (command.buildEveryMinutes != nil, "--build-every-minutes"),
            (!command.repo.isEmpty, "--repo"),
            (!command.cli.isEmpty, "--cli"),
            (command.route != nil, "--route"),
            (!command.fallback.isEmpty, "--fallback"),
            (command.boardConnection != nil, "--board-connection"),
            (command.boardConnectionName != nil, "--board-connection-name"),
            (command.operatorID != nil, "--operator"),
            (command.githubCredential != nil, "--github-credential"),
            (command.installGitHub, "--install-github"),
            (command.printGitHub, "--print-github"),
            (command.tokenStdin, "--token-stdin"),
            (command.fromGH, "--from-gh"),
            (command.replace, "--replace"),
            (!command.githubRepo.isEmpty, "--github-repo"),
            (command.skipGitHubCheck, "--skip-github-check")
        ]
        let present = forbidden.filter(\.0).map(\.1)
        guard present.isEmpty else {
            throw ValidationError(
                "\(flag) cannot be combined with " + present.joined(separator: ", ") // glossary:ignore GL001
            )
        }
    }

    /// `--print-choices` is exclusive with everything that generates or adopts configuration; it only
    /// takes the options that reach the Linear client, exactly as `--init` would.
    static func validatePrintChoicesScope(_ command: SetupCommand) throws {
        let forbidden: [(Bool, String)] = [
            (command.initialize, "--init"),
            (command.config != nil, "--config"),
            (command.project != nil, "--project"), // glossary:ignore GL001
            (command.projectName != nil, "--project-name"), // glossary:ignore GL001
            (command.linearTeam != nil, "--linear-team"),
            (command.specSource != nil, "--spec-source"),
            (command.nightStart != nil, "--night-start"),
            (command.nightEnd != nil, "--night-end"),
            (command.buildEveryMinutes != nil, "--build-every-minutes"),
            (!command.repo.isEmpty, "--repo"),
            (!command.cli.isEmpty, "--cli"),
            (command.route != nil, "--route"),
            (!command.fallback.isEmpty, "--fallback"),
            (command.operatorID != nil, "--operator"),
            (command.installJobs, "--install-jobs"),
            (command.exportJobs != nil, "--export-jobs"),
            (command.cron, "--cron"),
            (command.installLinear, "--install-linear"),
            (command.boardConnectionName != nil, "--board-connection-name"),
            (command.installCLI, "--install-cli"),
            (command.uninstallCLI, "--uninstall-cli")
        ]
        let present = forbidden.filter(\.0).map(\.1)
        guard present.isEmpty else {
            throw ValidationError(
                "--print-choices cannot be combined with " + present.joined(separator: ", ") // glossary:ignore GL001
            )
        }
        if command.linearProject != nil && command.boardConnection == nil {
            throw ValidationError(
                "--linear-project with --print-choices requires --board-connection" // glossary:ignore GL001
            )
        }
    }
}
