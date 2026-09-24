import CLIAdapters
import Config
import Domain
import Engine
import Foundation

extension Setup {
    /// `--print-choices`: never prompts, writes no configuration file. Loads `config.toml` when present
    /// (invalid means throw, as elsewhere), or builds one in memory from `--linear-client-id` and the
    /// credential defaults; resolves the Linear client secret exactly as `resolveLinearSecret` does — so
    /// `--linear-client-secret-stdin` still stores it in the Keychain — then binds the workspace board,
    /// authorizes, and reads its teams. Prints exactly one line: the JSON-encoded ``SetupChoices``.
    func printChoices() async throws {
        let machine = try loadMachineConfigurationForChoices()
        let secret = try resolveLinearSecret(machine: machine)
        let board = try bindWorkspaceBoard(machine: machine, secret: secret)
        let members = try await authorize(board: board)
        let teams = try await fetchTeams(board: board)
        output(try encodeChoicesJSON(makeChoices(machine: machine, members: members, teams: teams)))
    }

    private func loadMachineConfigurationForChoices() throws -> MachineConfiguration {
        let path = machineFileURL.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: path) {
            do {
                return try MachineConfiguration.load(contentsOf: machineFileURL)
            } catch {
                throw SetupError("\(path) is invalid: \(error)")
            }
        }
        guard let linearClientID = options.linearClientID else {
            throw SetupError("--linear-client-id is required to create \(path)")
        }
        // Non-empty literals: never fail.
        let linearCredential = options.linearCredential ?? CredentialReference(SetupOptions.defaultLinearCredential)!
        let gitHubCredential = options.githubCredential ?? CredentialReference(SetupOptions.defaultGitHubCredential)!
        return MachineConfiguration(
            linearClientID: linearClientID, linearCredential: linearCredential, gitHubCredential: gitHubCredential,
            cliAdapters: [], routingTable: []
        )
    }

    private func fetchTeams(board: any BoardProvisioning) async throws -> [BoardTeam] {
        do {
            return try await board.teams()
        } catch {
            throw SetupError("Linear authorization failed: \(error)")
        }
    }

    private func makeChoices(
        machine: MachineConfiguration, members: [BoardMember], teams: [BoardTeam]
    ) -> SetupChoices {
        let candidates = OperatorIdentity.candidates(from: members)
        let configuredOperator = machine.operatorIdentity.flatMap { configured in
            candidates.contains { $0.id == configured } ? configured.rawValue : nil
        }
        return SetupChoices(
            operatorCandidates: candidates.map {
                SetupChoices.Member(id: $0.id.rawValue, name: $0.name, displayName: $0.displayName)
            },
            configuredOperator: configuredOperator,
            teams: teams.map { SetupChoices.Team(id: $0.id.rawValue, key: $0.key, name: $0.name) },
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
