import Config
import Domain
import Engine
@testable import EngineCommand
import Foundation
import Testing

/// `BoardBinding` never eagerly reads the Keychain (P17.4): construction succeeds, and a missing
/// or unreadable Installation token pair only ever surfaces from the first Linear call the adapter
/// makes, as `.notAuthenticated` naming the setup fix (`LinearInstallationTokenSource`'s own job, P17.3).
struct BoardBindingTests {
    private func makeMachineAndProject(credential: String) throws -> (MachineConfiguration, ProjectConfiguration) {
        let machine = try MachineConfiguration.parse("""
            [board.linear.connections.acme]
            credential = "\(credential)"
            workspace = "workspace-1"
            yellowhammer_identity = "app-user-1"

            [code_hosting.github.connections.github]
            type = "keychain"
            credential = "keychain:github"
            """, file: "config.toml")
        let project = try ProjectConfiguration.parse("""
            id = "yellowhammer"
            name = "Yellowhammer"
            board = { linear = { connection = "acme", project = "7f1c2d9e-3b4a-4c5d-8e6f-0a1b2c3d4e5f" } }
            code_hosting = { connection = "github" }
            spec_source = "~/Developer/yellowhammer-spec"

            [[repos]]
            name = "backend"
            path = "~/Developer/yellowhammer-backend"
            role = "backend"
            check = "swift test"
            """, file: "yellowhammer.toml")
        return (machine, project)
    }

    @Test("Binding never touches the Keychain: construction succeeds even with no Installation at all")
    func bindingNeverThrows() throws {
        let account = "yh-test-absent-\(UUID().uuidString)"
        let (machine, project) = try makeMachineAndProject(credential: "keychain:\(account)")

        _ = try BoardBinding.board(machine: machine, project: project)
        _ = try BoardBinding.provisioning(machine: machine, project: project)
        _ = try BoardBinding.actBoard(machine: machine, project: project)
    }

    @Test("A missing Installation token pair fails only the first Linear call, as notAuthenticated")
    func missingInstallationFailsFirstCall() async throws {
        let account = "yh-test-absent-\(UUID().uuidString)"
        let (machine, project) = try makeMachineAndProject(credential: "keychain:\(account)")
        // A lock file under a throwaway temp home: this test never installs anything, so the lock is
        // never contended, but binding still needs a real, writable path to open.
        let homeDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-binding-home-\(UUID().uuidString)", directoryHint: .isDirectory)

        let board = try BoardBinding.board(machine: machine, project: project, homeDirectory: homeDirectory)

        do {
            _ = try await board.identity()
            Issue.record("expected the first Linear call to fail")
        } catch .notAuthenticated(let message) {
            #expect(message.contains("re-run the Linear step of yh setup"))
        } catch {
            Issue.record("expected notAuthenticated, got \(error)")
        }
    }

    private func projectFile(id: String, installation: String) -> String {
        """
        id = "\(id)"
        name = "\(id)"
        spec_source = "~/Developer/\(id)-spec"

        [board.linear]
        connection = "\(installation)"
        project = "\(id.uppercased())"

        [code_hosting]
        connection = "github"

        [[repos]]
        name = "backend"
        path = "~/Developer/\(id)-backend"
        role = "backend"
        check = "swift test"
        """
    }

    @Test("an Act binds the Project's own installation's credential and Operator")
    func actBindsOwnInstallation() throws {
        let uuid = UUID().uuidString
        let machine = try MachineConfiguration.parse("""
            [board.linear.connections.acme]
            credential = "keychain:yh-test-a-\(uuid)"
            workspace = "workspace-a"
            yellowhammer_identity = "app-user-a"
            operator = "op-a"

            [board.linear.connections.beta]
            credential = "keychain:yh-test-b-\(uuid)"
            workspace = "workspace-b"
            yellowhammer_identity = "app-user-b"
            operator = "op-b"

            [code_hosting.github.connections.github]
            type = "keychain"
            credential = "keychain:github"
            """, file: "config.toml")
        let homeDirectory = FileManager.default.temporaryDirectory
        let cases = [("alpha", "acme", "a", "op-a"), ("bravo", "beta", "b", "op-b")]
        var projects: [ProjectConfiguration] = []
        for (id, installation, _, _) in cases {
            projects.append(try ProjectConfiguration.parse(
                projectFile(id: id, installation: installation), file: "\(id).toml"
            ))
        }
        let configuration = Configuration(
            machine: machine, projects: projects, invalidProjects: [], routingTables: [:]
        )
        for (project, expected) in zip(projects, cases) {
            let installation = try #require(machine.linearInstallation(for: project))
            let store = BoardBinding.installationStore(
                for: installation, credentials: KeychainCredentialStore(), homeDirectory: homeDirectory
            )
            #expect(store.reference.rawValue == "keychain:yh-test-\(expected.2)-\(uuid)")
            #expect(
                LandCommand.operatorIdentity(configuration: configuration, project: project)
                    == OperatorIdentity(configured: BoardObjectID(rawValue: expected.3))
            )
            _ = try BoardBinding.actBoard(machine: machine, project: project)
        }
    }

    @Test("A Project whose installation is not in the machine file cannot be bound")
    func missingInstallationThrows() throws {
        let (machine, _) = try makeMachineAndProject(credential: "keychain:yh-test-x-\(UUID().uuidString)")
        let orphan = try ProjectConfiguration.parse(
            projectFile(id: "orphan", installation: "gone"), file: "orphan.toml"
        )
        #expect(throws: BoardBindingError.installationMissing(project: orphan.id, installation: "gone")) {
            _ = try BoardBinding.actBoard(machine: machine, project: orphan)
        }
        let message = BoardBindingError.installationMissing(project: orphan.id, installation: "gone").description
        #expect(message.contains("orphan"))
        #expect(message.contains("\"gone\""))
        #expect(machine.linearInstallation(for: orphan) == nil)
    }

    private func machine(descriptionBudget: Int?) throws -> MachineConfiguration {
        let budgetLine = descriptionBudget.map { "description_budget = \($0)" } ?? ""
        return try MachineConfiguration.parse("""
            [board.linear.connections.acme]
            credential = "keychain:yh-test-budget-\(UUID().uuidString)"
            workspace = "workspace-1"
            yellowhammer_identity = "app-user-1"
            \(budgetLine)

            [code_hosting.github.connections.github]
            type = "keychain"
            credential = "keychain:github"
            """, file: "config.toml")
    }

    @Test("An Act's board carries the Board Connection's description budget, 10,000 when unset")
    func actBoardCarriesDescriptionBudget() throws {
        let project = try ProjectConfiguration.parse(projectFile(id: "alpha", installation: "acme"), file: "alpha.toml")
        let unset = try BoardBinding.actBoard(machine: try machine(descriptionBudget: nil), project: project)
        #expect(unset.descriptionBudget?.value == 10_000)
        #expect(unset.descriptionBudget?.limit == BoardDescriptionLimit(maximum: 250_000, unit: .utf16CodeUnits))
        let ceiling = try BoardBinding.actBoard(machine: try machine(descriptionBudget: 225_000), project: project)
        #expect(ceiling.descriptionBudget?.value == 225_000)
    }

    @Test("A description budget above Linear's ceiling is refused at binding, naming the ceiling")
    func descriptionBudgetAboveCeilingRefused() throws {
        let project = try ProjectConfiguration.parse(projectFile(id: "alpha", installation: "acme"), file: "alpha.toml")
        let configured = try machine(descriptionBudget: 225_001)
        do {
            _ = try BoardBinding.actBoard(machine: configured, project: project)
            Issue.record("expected 225001 to be refused")
        } catch let error as ConfigurationError {
            #expect(error.key == "board.linear.connections.acme.description_budget")
            #expect(error.reason == .aboveDescriptionBudgetCeiling(
                value: 225_001, ceiling: 225_000, limit: BoardDescriptionLimit(maximum: 250_000, unit: .utf16CodeUnits)
            ))
            #expect(error.description.contains("225000"))
        } catch {
            Issue.record("expected a ConfigurationError, got \(error)")
        }
    }
}
