import Config
import Domain
import Testing

@Suite("Setup readiness")
struct SetupReadinessTests {
    private func machine(
        operatorIdentity: String? = "user-1", adapters: [String] = ["claude"], route: String = "claude",
        fallbacks: [String] = []
    ) throws -> MachineConfiguration {
        MachineConfiguration(
            linearInstallations: [
                LinearInstallation(
                    name: "acme",
                    credential: try editingCredential("keychain:linear"),
                    workspace: BoardObjectID(rawValue: "workspace-1"),
                    appUser: BoardObjectID(rawValue: "app-user-1"),
                    operatorIdentity: operatorIdentity.flatMap { BoardObjectID(rawValue: $0) }
                )
            ],
            gitHubCredential: try editingCredential("keychain:github"),
            cliAdapters: adapters.map { CLIAdapterDeclaration(name: $0) },
            routingTable: [
                RoutingEntry(
                    route: try editingRoute(route, "sonnet"),
                    fallbacks: try fallbacks.map { try editingRoute($0, "sonnet") }
                )
            ]
        )
    }

    @Test("A route present blocks nothing")
    func allPresent() throws {
        let readiness = SetupReadiness(machine: try machine())
        #expect(readiness.missing.isEmpty)
        #expect(!readiness.blocksAddProject)
    }

    @Test("A missing Operator identity does not block: the Linear step owns it")
    func operatorIdentityIsNotAPrerequisite() throws {
        #expect(SetupReadiness(machine: try machine(operatorIdentity: nil)).missing.isEmpty)
    }

    @Test("A missing route blocks with exactly that one")
    func noRoute() throws {
        let readiness = SetupReadiness(machine: try machine(adapters: ["codex"]))
        #expect(readiness.missing == [.agentCLIRoute])
        #expect(readiness.blocksAddProject)
    }

    @Test("No machine file lacks the route")
    func noMachine() {
        let readiness = SetupReadiness(machine: nil)
        #expect(readiness.missing == SetupReadiness.Prerequisite.allCases)
        #expect(readiness.missing == [.agentCLIRoute])
    }

    @Test("A fallback naming a declared CLI counts; a route naming an undeclared CLI does not")
    func fallbackCounts() throws {
        let viaFallback = SetupReadiness(
            machine: try machine(adapters: ["codex"], route: "claude", fallbacks: ["codex"])
        )
        #expect(viaFallback.missing.isEmpty)
        let undeclared = SetupReadiness(
            machine: try machine(adapters: ["codex"], route: "claude", fallbacks: ["gemini"])
        )
        #expect(undeclared.missing == [.agentCLIRoute])
    }

    @Test("A route to a CLI whose executable cannot run does not count, and says why")
    func unrunnableExecutable() throws {
        var configuration = try machine()
        configuration.cliAdapters[0].executable = "/nonexistent/claud"
        let readiness = SetupReadiness(machine: configuration)
        #expect(readiness.missing == [.agentCLIRoute])
        #expect(readiness.executableProblems.count == 1)
        #expect(readiness.executableProblems.first?.contains("/nonexistent/claud") == true)
        #expect(SetupReadiness(machine: try machine()).executableProblems.isEmpty)
    }

    @Test("Every prerequisite has a title")
    func titles() {
        #expect(SetupReadiness.Prerequisite.allCases.map(\.title) == ["An agent CLI with a route"])
    }
}
