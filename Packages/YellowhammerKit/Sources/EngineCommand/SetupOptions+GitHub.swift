import ArgumentParser

extension SetupOptions {
    /// `--skip-github-check` belongs to a run that writes a Project: `--init` with `--project`, or interactive.
    static func validateSkipGitHubCheck(_ command: SetupCommand) throws {
        guard command.skipGitHubCheck else { return }
        let forbidden: [(Bool, String)] = [
            (command.config != nil, "--config"),
            (command.installLinear, "--install-linear"),
            (command.printChoices, "--print-choices")
        ]
        let present = forbidden.filter(\.0).map(\.1)
        guard present.isEmpty else {
            throw ValidationError("--skip-github-check cannot be combined with " + present.joined(separator: ", "))
        }
        guard !command.initialize || command.project != nil else {
            throw ValidationError("--skip-github-check with --init requires --project") // glossary:ignore GL001
        }
    }
}
