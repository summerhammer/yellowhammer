import ArgumentParser
import Config
import Domain
import Engine
import Foundation
import Repositories

/// `yh project remove <id>`: explicit Project removal (roadmap P13.5; spec risks.md OQ52(1)).
public struct ProjectRemoveCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a Project's machine-local footprint: LaunchAgents, logs and held Worktrees."
    )

    @Argument(help: "The id of the Project to remove.")
    public var id: String

    @Flag(help: "Remove without asking for confirmation.")
    public var yes: Bool = false

    public init() {}

    public func run() async throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        try await run(configurationDirectory: Configuration.defaultDirectoryURL(homeDirectory: homeDirectory))
    }

    func run(configurationDirectory: URL) async throws {
        let removal = ProjectRemoval(
            configurationDirectory: configurationDirectory,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            output: { print($0) },
            console: RealSetupConsole(),
            launchAgents: LaunchctlLaunchAgentControl(),
            bindBoard: { configuration, project in
                BoardBinding.actBoard(machine: configuration.machine, project: project).writing
            },
            workspace: WorkspaceBinding.workspace(),
            git: GitRunner(),
            bindPush: { configuration, project in Self.push(configuration: configuration, project: project) },
            now: Date()
        )
        guard await removal.run(id: id, yes: yes) else {
            throw ExitCode(1)
        }
    }

    /// The push seam, mirroring ``LandBinding/push(configuration:project:credentials:)``: the GitHub
    /// token is resolved lazily, on each call, so a removal that never pushes never touches the
    /// Keychain.
    private static func push(
        configuration: Configuration,
        project: ProjectConfiguration,
        credentials store: KeychainCredentialStore = KeychainCredentialStore()
    ) -> @Sendable (FeatureBranch, Repo, NightMode) async -> PushOutcome {
        { branch, repo, mode in
            let token: GitHubToken?
            do {
                let reference = configuration.machine.gitHubCredential(for: project)
                token = GitHubToken(try store.read(reference))
            } catch {
                return .credentialsMissingOrInsufficient(repository: repo.name, detail: "\(error)")
            }
            return await FeatureBranchPusher().push(branch: branch, in: repo, mode: mode, token: token)
        }
    }
}
