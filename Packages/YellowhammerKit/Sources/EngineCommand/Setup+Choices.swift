import CLIAdapters
import Config
import Domain
import Engine
import Foundation

extension Setup {
    /// `--print-choices`: never prompts, writes no configuration file. Loads `config.toml` when present
    /// (invalid means throw, as elsewhere), or reads none; then binds the sole App Installation's board, authorizes, and reads its teams and Linear projects. Its last line is the
    /// JSON-encoded ``SetupChoices``, the line the app decodes; a failed Linear projects read is reported
    /// on one `warning:` line before it.
    func printChoices() async throws {
        let machine = try loadMachineConfigurationForChoices()
        let installation = try soleInstallationForChoices(machine)
        guard credentials.secret(for: installation.credential) != nil else {
            throw SetupError(
                "Yellowhammer is not installed in a Linear workspace yet; run yh setup --install-linear"
            )
        }
        let board = bindProvisioning(installation, "")
        let members = try await authorize(board: board)
        let teams = try await fetchTeams(board: board)
        // A failed projects read must not cost the Operator the teams and candidates already in hand:
        // the step falls back to pasting an id, so it prints an empty list, and says why.
        let projects: [BoardLinearProject]
        do {
            projects = try await board.linearProjects()
        } catch {
            output("warning: could not list the Linear projects: \(error)") // glossary:ignore GL001
            projects = []
        }
        output(try encodeChoicesJSON(
            makeChoices(installation: installation, members: members, teams: teams, projects: projects)
        ))
    }

    private func loadMachineConfigurationForChoices() throws -> MachineConfiguration? {
        let path = machineFileURL.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: path) {
            do {
                return try MachineConfiguration.load(contentsOf: machineFileURL)
            } catch {
                throw SetupError("\(path) is invalid: \(error)")
            }
        }
        return nil
    }

    /// Choices are read through exactly one App Installation (the machine-only bridge, roadmap L3.2).
    private func soleInstallationForChoices(_ machine: MachineConfiguration?) throws -> LinearInstallation {
        let count = machine?.linearInstallations.count ?? 0
        guard count > 0, let machine else {
            throw SetupError(
                "Yellowhammer is not installed in a Linear workspace yet; run yh setup --install-linear"
            )
        }
        guard let sole = machine.soleLinearInstallation else {
            throw SetupError(
                "config.toml declares \(count) Linear App Installations; "
                    + "this version of yh setup --print-choices reads one"
            )
        }
        return sole
    }

    private func fetchTeams(board: any BoardProvisioning) async throws -> [BoardTeam] {
        do {
            return try await board.teams()
        } catch {
            throw SetupError("Linear authorization failed: \(error)")
        }
    }

    private func makeChoices(
        installation: LinearInstallation, members: [BoardMember], teams: [BoardTeam],
        projects: [BoardLinearProject]
    ) -> SetupChoices {
        let candidates = OperatorIdentity.candidates(from: members)
        let configuredOperator = installation.operatorIdentity.flatMap { configured in
            candidates.contains { $0.id == configured } ? configured.rawValue : nil
        }
        return SetupChoices(
            operatorCandidates: candidates.map {
                SetupChoices.Member(id: $0.id.rawValue, name: $0.name, displayName: $0.displayName)
            },
            configuredOperator: configuredOperator,
            teams: teams.map { SetupChoices.Team(id: $0.id.rawValue, key: $0.key, name: $0.name) },
            linearProjects: projects.filter { !$0.isCompleted && !$0.isCanceled }.map { project in
                SetupChoices.LinearProject(
                    id: project.id.rawValue, name: project.name, teamNames: project.teams.map(\.name)
                )
            },
            cliAdapters: CLIAdapterRegistry.allNames
        )
    }

    private func encodeChoicesJSON(_ choices: SetupChoices) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(choices)
            guard let text = String(data: data, encoding: .utf8) else {
                throw SetupError("could not encode choices as JSON")
            }
            return text
        } catch let error as SetupError {
            throw error
        } catch {
            throw SetupError("could not encode choices as JSON: \(error)")
        }
    }
}
