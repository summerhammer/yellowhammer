import ArgumentParser
import Config
import Domain
import Foundation
import Repositories

/// `yh project set-code-hosting-connection <project> <connection>`: changes a Project's selected Code Hosting
/// Connection (`[code_hosting] connection`). It runs the push check against every working Repo first (skipping
/// spec-role Repos) and saves only if the check passes.
public struct ProjectSetCodeHostingConnectionCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "set-code-hosting-connection",
        abstract: "Select or change a Project's Code Hosting Connection.",
        aliases: ["select-code-hosting-connection", "set-code-hosting"]
    )

    @Argument(help: "The id of the Project.")
    public var project: String?

    @Argument(help: "The name of the Code Hosting Connection to select.")
    public var connection: String?

    @Option(name: .customLong("project"), help: "The id of the Project.")
    public var projectOption: String?

    @Option(name: .customLong("connection"), help: "The name of the Code Hosting Connection to select.")
    public var connectionOption: String?

    public init() {}

    public func validate() throws {
        let proj = project ?? projectOption
        guard let proj, !proj.isEmpty else {
            throw ValidationError("specify the Project id as an argument or with --project")
        }
        let conn = connection ?? connectionOption
        guard let conn, !conn.isEmpty else {
            throw ValidationError("specify the Code Hosting Connection name as an argument or with --connection")
        }
    }

    public func run() async throws {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        try await run(configurationDirectory: Configuration.defaultDirectoryURL(homeDirectory: homeDirectory))
    }

    func run(
        configurationDirectory: URL,
        credentials: any SetupCredentialStore = KeychainSetupCredentialStore(),
        gitHub: GitHubCredentialValidation = .production(),
        output: @escaping (String) -> Void = { print($0) }
    ) async throws {
        let projID = project ?? projectOption ?? ""
        let connName = connection ?? connectionOption ?? ""
        let change = ProjectCodeHostingConnectionChange(
            configurationDirectory: configurationDirectory,
            credentials: credentials,
            gitHub: gitHub,
            output: output
        )
        try await change.run(projectID: projID, connectionName: connName)
    }
}

/// Orchestrates changing a Project's Code Hosting Connection.
struct ProjectCodeHostingConnectionChange {
    let configurationDirectory: URL
    let credentials: any SetupCredentialStore
    let gitHub: GitHubCredentialValidation
    let output: (String) -> Void

    private func connectedListing(_ machine: MachineConfiguration, fixing name: String) -> String {
        let names = machine.codeHostingConnections.map(\.name)
        guard names.isEmpty else { return "connected: " + names.joined(separator: ", ") }
        return "none are connected; connect one with `yh config connect-code-hosting \(name) --token-stdin`"
    }

    func run(projectID: String, connectionName: String) async throws {
        let (configuration, project): (Configuration, ProjectConfiguration)
        do {
            (configuration, project) = try ProjectResolution.resolve(
                projectArgument: projectID,
                configurationDirectory: configurationDirectory
            )
        } catch {
            throw SetupError("\(error)")
        }

        guard let connection = configuration.machine.codeHostingConnection(named: connectionName) else {
            throw SetupError(
                "\(connectionName) is not a connected Code Hosting Connection ("
                    + connectedListing(configuration.machine, fixing: connectionName) + ")"
            )
        }

        guard case .keychainToken(let reference) = connection.kind else {
            throw SetupError(CodeHostingRefusal.githubCLINotSupported(connection: connectionName).description)
        }

        try await validatePushAccess(connectionName: connectionName, reference: reference, project: project)
        try saveProject(project: project, connectionName: connectionName)

        output("Code Hosting Connection for Project \(project.id.rawValue) set to \(connectionName).")
    }

    private func validatePushAccess(
        connectionName: String,
        reference: CredentialReference,
        project: ProjectConfiguration
    ) async throws {
        let workingRepos = project.repositories.workingRepos.filter { $0.role != .spec }
        let reposToCheck = workingRepos.map { (name: $0.name, path: $0.path) }

        let secret = credentials.gitHubSecret(for: reference)
        let report = await gitHub.report(
            reference: reference,
            secret: secret,
            repos: reposToCheck,
            connectionName: connectionName
        )

        guard report.isValid else {
            if report.state != .resolves {
                throw SetupError(report.message, gitHub: true)
            }
            let failureMessage = report.repos.first { $0.status != .ok && $0.status != .okUnverified }?.message
                ?? report.message
            throw SetupError(failureMessage, gitHub: true)
        }

        for repo in report.repos where repo.status == .okUnverified {
            output(repo.message)
        }
    }

    private func saveProject(project: ProjectConfiguration, connectionName: String) throws {
        let projectFileURL = configurationDirectory
            .appending(components: "projects", "\(project.id.rawValue).toml", directoryHint: .notDirectory)
        let originalText: String
        do {
            originalText = try String(contentsOf: projectFileURL, encoding: .utf8)
        } catch {
            throw SetupError("could not read \(projectFileURL.path(percentEncoded: false)): \(error)")
        }

        let updatedText = ProjectConfiguration.settingCodeHostingConnection(
            named: connectionName, inFileText: originalText
        )
        do {
            try Configuration.save(
                updatedText, to: projectFileURL, in: configurationDirectory, replacing: originalText
            )
        } catch {
            throw SetupError("could not save \(projectFileURL.path(percentEncoded: false)): \(error)")
        }
    }
}
