import ArgumentParser
import Foundation

/// Where `--install-github` gets the token.
enum GitHubTokenSource: Equatable {
    /// Neither `--token-stdin` nor `--from-gh`: offer the GitHub CLI's token, else ask with hidden input.
    case prompt
    /// `--token-stdin`: one line from standard input.
    case standardInput
    /// `--from-gh`: `gh auth token`.
    case githubCLI
}

/// The options of the GitHub step (`--install-github` / `--print-github`).
struct GitHubStepOptions {
    /// `--token-stdin` / `--from-gh`.
    let tokenSource: GitHubTokenSource
    /// `--replace`: capture a token even when the stored one works.
    let replace: Bool
    /// `--github-repo`, in order: the Repo paths to check the token against.
    let repoPaths: [String]
    /// `--skip-github-check`: write a Project without checking that the token can push to its Repos (a
    /// rehearsal-only Project never pushes).
    let skipCheck: Bool

    init(command: SetupCommand) throws {
        skipCheck = command.skipGitHubCheck
        tokenSource = command.tokenStdin ? .standardInput : command.fromGH ? .githubCLI : .prompt
        replace = command.replace
        repoPaths = try command.githubRepo.map { path in
            guard !path.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ValidationError("--github-repo must not be empty")
            }
            return path
        }
    }
}

extension SetupOptions {
    var gitHubTokenSource: GitHubTokenSource { gitHub.tokenSource }
    var replaceGitHubToken: Bool { gitHub.replace }
    var gitHubRepoPaths: [String] { gitHub.repoPaths }
    var skipGitHubCheck: Bool { gitHub.skipCheck }

    /// The GitHub step's own flags without `--install-github` or `--print-github` are refused.
    static func validateGitHubOptionsWithoutMode(_ command: SetupCommand) throws {
        guard !command.tokenStdin, !command.fromGH, !command.replace else {
            throw ValidationError("--token-stdin, --from-gh and --replace require --install-github")
        }
        guard command.githubRepo.isEmpty else {
            throw ValidationError("--github-repo requires --install-github or --print-github")
        }
        try validateSkipGitHubCheck(command)
    }

    /// `--skip-github-check` belongs to a run that writes a Project: `--init` with `--project`, or interactive.
    private static func validateSkipGitHubCheck(_ command: SetupCommand) throws {
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

    /// `--install-github` and `--print-github` are exclusive with each other and with everything that
    /// generates, adopts or schedules configuration; the token-source flags belong to `--install-github`.
    static func validateGitHubScope(_ command: SetupCommand) throws {
        guard !(command.installGitHub && command.printGitHub) else {
            throw ValidationError("--install-github and --print-github are mutually exclusive")
        }
        let flag = command.installGitHub ? "--install-github" : "--print-github"
        let forbidden: [(Bool, String)] = [
            (command.initialize, "--init"),
            (command.config != nil, "--config"),
            (command.installLinear, "--install-linear"),
            (command.printChoices, "--print-choices"),
            (command.project != nil, "--project"), // glossary:ignore GL001
            (!command.cli.isEmpty, "--cli"),
            (command.route != nil, "--route"),
            (!command.fallback.isEmpty, "--fallback"),
            (command.installJobs, "--install-jobs"),
            (command.exportJobs != nil, "--export-jobs"),
            (command.cron, "--cron"),
            (command.skipGitHubCheck, "--skip-github-check")
        ]
        let present = forbidden.filter(\.0).map(\.1)
        guard present.isEmpty else {
            throw ValidationError("\(flag) cannot be combined with " + present.joined(separator: ", "))
        }
        guard !(command.tokenStdin && command.fromGH) else {
            throw ValidationError("--token-stdin and --from-gh are mutually exclusive")
        }
        guard command.installGitHub || (!command.tokenStdin && !command.fromGH && !command.replace) else {
            throw ValidationError("--token-stdin, --from-gh and --replace require --install-github")
        }
    }
}
