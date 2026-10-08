import Config
import Domain
import Foundation
import Testing

/// Shared fixtures for ``ConfigurationEditingTests`` and ``ConfigurationEditingRefusalTests``: every
/// scenario gets its own temp directory holding a `config.toml` and a `projects/` directory.

func editingRoute(_ cli: String, _ model: String, _ effort: String = "medium") throws -> Route {
    try #require(Route(cli: cli, model: model, effort: effort))
}

func editingKind(_ string: String) throws -> Kind {
    try #require(Kind(string))
}

func editingCredential(_ string: String) throws -> CredentialReference {
    try #require(CredentialReference(string))
}

func editingProjectID(_ string: String) throws -> ProjectID {
    try #require(ProjectID(rawValue: string))
}

func makeEditingDirectory(machine: MachineConfiguration, projects: [ProjectConfiguration]) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("yellowhammer-config-edit-tests-\(UUID().uuidString)")
    let projectsDirectory = directory.appendingPathComponent("projects")
    try FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
    try machine.renderedTOML.write(
        to: directory.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8
    )
    for project in projects {
        try project.renderedTOML.write(
            to: projectsDirectory.appendingPathComponent("\(project.id.rawValue).toml"),
            atomically: true,
            encoding: .utf8
        )
    }
    return directory
}

func cleanupEditingDirectory(_ directory: URL) {
    try? FileManager.default.removeItem(at: directory)
}

func editingMachineFileURL(_ directory: URL) -> URL {
    directory.appendingPathComponent("config.toml")
}

func editingProjectFileURL(_ directory: URL, _ id: String) -> URL {
    directory.appendingPathComponent("projects").appendingPathComponent("\(id).toml")
}

func testEditingMachine(cliAdapters: [String] = ["claude", "codex"]) throws -> MachineConfiguration {
    MachineConfiguration(
        linearInstallations: [
            LinearInstallation(
                name: "acme",
                credential: try editingCredential("keychain:linear"),
                workspace: BoardObjectID(rawValue: "workspace-1"),
                appUser: BoardObjectID(rawValue: "app-user-1")
            )
        ],
        codeHostingConnections: [
            CodeHostingConnection(name: "github", kind: .keychainToken(try editingCredential("keychain:github")))
        ],
        cliAdapters: cliAdapters.map { CLIAdapterDeclaration(name: $0) },
        routingTable: [RoutingEntry(route: try editingRoute("claude", "sonnet", "medium"))]
    )
}

func testEditingProject(
    id: String, name: String = "Test Project", linearProject: String = "TP",
    repos: [RepoDeclaration]? = nil, routingOverrides: [RoutingEntry] = []
) throws -> ProjectConfiguration {
    ProjectConfiguration(
        id: try editingProjectID(id),
        name: name,
        linearInstallationName: "acme",
        linearProject: linearProject,
        codeHostingConnectionName: "github",
        specSource: "~/dev/\(id)-spec",
        repos: repos ?? [
            RepoDeclaration(name: "backend", path: "~/dev/\(id)-backend", role: .backend, check: .none)
        ],
        routingOverrides: routingOverrides
    )
}
