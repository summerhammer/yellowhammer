import Config
import Domain
import Engine
import Foundation

extension Setup {
    /// "Declare a Project now? [y/N]", looped: on success, offers another; on a validation or Linear
    /// error, prints it and restarts that Project's own prompts rather than moving on.
    func interactiveProjectLoop(
        machine: MachineConfiguration, installation: LinearInstallation, board: any BoardProvisioning
    ) async throws {
        guard askYesNo("Declare a Project now? [y/N] ") else { return }
        while true {
            let declaration = try await askProjectDeclaration(board: board)
            do {
                try await writeProject(declaration, machine: machine, installation: installation, board: board)
            } catch {
                output("\(error)")
                if let failure = error as? SetupError, failure.isGitHubFailure {
                    try await offerGitHubReplacement(machine: machine)
                }
                continue
            }
            guard askYesNo("Declare another Project? [y/N] ") else { return }
        }
    }

    private func askProjectDeclaration(board: any BoardProvisioning) async throws -> ProjectDeclaration {
        let id = try askProjectID()
        let name = try askProjectName(defaultID: id)
        let linearProject = try await askLinearProjectChoice(board: board)
        let specSource = try askSpecSource()
        let repos = try askRepos()
        return ProjectDeclaration(
            id: id, name: name, linearProject: linearProject, specSource: specSource, repos: repos
        )
    }

    private func askProjectID() throws -> ProjectID {
        while true {
            guard let line = console.ask("Project id: ") else { throw SetupError("setup was cancelled") }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let id = ProjectID(rawValue: trimmed) else {
                output("Project id must contain only letters, digits, underscores and hyphens")
                continue
            }
            let projectFileURL = configurationDirectory.appending(
                components: "projects", "\(id.rawValue).toml", directoryHint: .notDirectory
            )
            guard !FileManager.default.fileExists(atPath: projectFileURL.path(percentEncoded: false)) else {
                output("a Project file for \"\(id.rawValue)\" already exists")
                continue
            }
            return id
        }
    }

    private func askProjectName(defaultID id: ProjectID) throws -> String {
        guard let line = console.ask("Project name [\(id.rawValue)]: ") else {
            throw SetupError("setup was cancelled")
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? id.rawValue : trimmed
    }

    private func askLinearProjectChoice(
        board: any BoardProvisioning
    ) async throws -> ProjectDeclaration.LinearProjectChoice {
        guard let line = console.ask("Linear project id (empty to create one): ") else { // glossary:ignore GL001
            throw SetupError("setup was cancelled")
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty else { return .existing(trimmed) }

        let teams: [BoardTeam]
        do {
            teams = try await board.teams()
        } catch {
            throw SetupError("Linear authorization failed: \(error)")
        }
        guard !teams.isEmpty else {
            throw SetupError("the workspace has no teams to create a Linear project in") // glossary:ignore GL001
        }
        for (index, team) in teams.enumerated() {
            output("\(index + 1)) \(team.name) (\(team.key))")
        }
        while true {
            guard let numberLine = console.ask("Team (number): ") else { throw SetupError("setup was cancelled") }
            guard let number = Int(numberLine.trimmingCharacters(in: .whitespaces)),
                  (1...teams.count).contains(number)
            else {
                continue
            }
            return .createInTeam(key: teams[number - 1].key)
        }
    }

    private func askSpecSource() throws -> String? {
        guard let line = console.ask("Spec Source path (empty for a Repo of role spec): ") else {
            throw SetupError("setup was cancelled")
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// At least one Repo.
    private func askRepos() throws -> [RepoDeclaration] {
        var repos: [RepoDeclaration] = []
        while true {
            let name = try askRequired("Repo name: ")
            let path = try askRequired("Repo path: ")
            let role = try askRequired("Repo role: ")
            let check = try askRequired("Repo check (\"none\" allowed): ")
            repos.append(RepoDeclaration(
                name: name, path: path, role: RepoRole(rawValue: role),
                check: check == "none" ? .none : .command(check)
            ))
            guard askYesNo("Add another repo? [y/N] ") else { return repos }
        }
    }

    /// EOF answers "no", matching the shown default.
    private func askYesNo(_ prompt: String) -> Bool {
        guard let line = console.ask(prompt) else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed == "y" || trimmed == "yes"
    }
}
