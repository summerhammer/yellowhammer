import Config
import Domain
import Engine
import Foundation

extension Setup {
    /// Step 4: nothing under `--config` (Projects are already installed). Otherwise builds one
    /// ``ProjectDeclaration`` from the options under `--init`, or loops interactive prompts, and writes
    /// each through the one shared path.
    func writeProjectsIfNeeded(
        machine: MachineConfiguration, secret: String, board: any BoardProvisioning
    ) async throws {
        switch options.mode {
        case .config:
            return
        case .initialize:
            guard let declaration = try optionProjectDeclaration() else { return }
            try await writeProject(declaration, machine: machine, secret: secret, board: board)
        case .interactive:
            try await interactiveProjectLoop(machine: machine, secret: secret, board: board)
        }
    }

    private func optionProjectDeclaration() throws -> ProjectDeclaration? {
        guard let id = options.projectID else { return nil }
        let linearProject: ProjectDeclaration.LinearProjectChoice
        if let team = options.linearTeam {
            linearProject = .createInTeam(key: team)
        } else if let explicit = options.linearProjectID {
            linearProject = .existing(explicit)
        } else {
            throw SetupError("missing --linear-project or --linear-team") // glossary:ignore GL001
        }
        return ProjectDeclaration(
            id: id, name: options.projectName ?? id.rawValue, linearProject: linearProject,
            specSource: options.specSource, repos: options.repos
        )
    }

    /// Keeps an existing Project file untouched; otherwise validates its shape first (a bad declaration
    /// must not leave an orphan Linear project), resolves the Linear project — creating it in a team
    /// when asked — and writes the file.
    func writeProject(
        _ declaration: ProjectDeclaration, machine: MachineConfiguration, secret: String, board: any BoardProvisioning
    ) async throws {
        let projectFileURL = configurationDirectory.appending(
            components: "projects", "\(declaration.id.rawValue).toml", directoryHint: .notDirectory
        )
        let path = projectFileURL.path(percentEncoded: false)
        guard !FileManager.default.fileExists(atPath: path) else {
            output("kept \(path); Project options were ignored")
            return
        }

        let declaredCLIAdapters = Set(machine.cliAdapters.map(\.name))
        try validateProjectShape(declaration, declaredCLIAdapters: declaredCLIAdapters, at: path)

        let linearProjectID = try await resolveLinearProjectID(
            declaration.linearProject, name: declaration.name, board: board
        )
        let project = makeProjectConfiguration(declaration, linearProject: linearProjectID)
        do {
            try FileManager.default.createDirectory(
                at: projectFileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try project.renderedTOML.write(to: projectFileURL, atomically: true, encoding: .utf8)
        } catch {
            throw SetupError("could not write \(path): \(error)")
        }
        output("wrote \(path)")
    }

    private func makeProjectConfiguration(
        _ declaration: ProjectDeclaration, linearProject: String
    ) -> ProjectConfiguration {
        ProjectConfiguration(
            id: declaration.id, name: declaration.name, linearProject: linearProject,
            specSource: declaration.specSource, repos: declaration.repos, bounds: Bounds(), schedule: Schedule()
        )
    }

    private func validateProjectShape(
        _ declaration: ProjectDeclaration, declaredCLIAdapters: Set<String>, at path: String
    ) throws {
        let placeholder = makeProjectConfiguration(declaration, linearProject: "placeholder")
        do {
            _ = try ProjectConfiguration.parse(
                placeholder.renderedTOML, file: path, declaredCLIAdapters: declaredCLIAdapters
            )
        } catch {
            throw SetupError("Project \(declaration.id): \(error)")
        }
    }

    private func resolveLinearProjectID(
        _ choice: ProjectDeclaration.LinearProjectChoice, name: String, board: any BoardProvisioning
    ) async throws -> String {
        switch choice {
        case .existing(let id):
            return id
        case .createInTeam(let key):
            return try await createLinearProject(named: name, inTeamKeyed: key, board: board)
        }
    }

    private func createLinearProject(
        named name: String, inTeamKeyed key: String, board: any BoardProvisioning
    ) async throws -> String {
        let teams: [BoardTeam]
        do {
            teams = try await board.teams()
        } catch {
            throw SetupError("Linear authorization failed: \(error)")
        }
        guard let team = teams.first(where: { $0.key.lowercased() == key.lowercased() }) else {
            let known = teams.map(\.key).joined(separator: ", ")
            throw SetupError("no team keyed \"\(key)\"; known teams: \(known)")
        }
        // Created directly, not through `BoardProvisioner`: this board is bound to no Linear project, so
        // the provisioner's opening `linearProject()` read would ask Linear for an empty id. Step 6
        // provisions the new Linear project through a board bound to its id, and finds it present.
        do {
            let created = try await board.createLinearProject(name: name, team: team.id)
            output("created Linear project \"\(created.name)\" in team \(team.key)") // glossary:ignore GL001
            return created.id.rawValue
        } catch {
            let message = "could not create the Linear project in team \"\(key)\": \(error)" // glossary:ignore GL001
            throw SetupError(message)
        }
    }
}
