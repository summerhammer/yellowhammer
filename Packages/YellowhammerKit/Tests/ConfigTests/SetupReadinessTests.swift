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
            linearCredential: try editingCredential("keychain:linear"),
            gitHubCredential: try editingCredential("keychain:github"),
            cliAdapters: adapters.map { CLIAdapterDeclaration(name: $0) },
            routingTable: [
                RoutingEntry(
                    route: try editingRoute(route, "sonnet"),
                    fallbacks: try fallbacks.map { try editingRoute($0, "sonnet") }
                )
            ],
            operatorIdentity: operatorIdentity.flatMap { BoardObjectID(rawValue: $0) }
        )
    }

    @Test("Everything present blocks nothing")
    func allPresent() throws {
        let readiness = SetupReadiness(linearInstalled: true, machine: try machine())
        #expect(readiness.missing.isEmpty)
        #expect(!readiness.blocksAddProject)
    }

    @Test("Each prerequisite missing on its own blocks with exactly that one")
    func eachAlone() throws {
        let noLinear = SetupReadiness(linearInstalled: false, machine: try machine())
        #expect(noLinear.missing == [.linearInstallation])
        #expect(noLinear.blocksAddProject)

        let noOperator = SetupReadiness(linearInstalled: true, machine: try machine(operatorIdentity: nil))
        #expect(noOperator.missing == [.operatorIdentity])

        let noRoute = SetupReadiness(linearInstalled: true, machine: try machine(adapters: ["codex"]))
        #expect(noRoute.missing == [.agentCLIRoute])
    }

    @Test("No machine file lacks the Operator identity and the route")
    func noMachine() {
        let readiness = SetupReadiness(linearInstalled: true, machine: nil)
        #expect(readiness.missing == [.operatorIdentity, .agentCLIRoute])
        let none = SetupReadiness(linearInstalled: false, machine: nil)
        #expect(none.missing == SetupReadiness.Prerequisite.allCases)
    }

    @Test("A fallback naming a declared CLI counts; a route naming an undeclared CLI does not")
    func fallbackCounts() throws {
        let viaFallback = SetupReadiness(
            linearInstalled: true, machine: try machine(adapters: ["codex"], route: "claude", fallbacks: ["codex"])
        )
        #expect(viaFallback.missing.isEmpty)
        let undeclared = SetupReadiness(
            linearInstalled: true, machine: try machine(adapters: ["codex"], route: "claude", fallbacks: ["gemini"])
        )
        #expect(undeclared.missing == [.agentCLIRoute])
    }

    @Test("Every prerequisite has a title")
    func titles() {
        #expect(SetupReadiness.Prerequisite.allCases.map(\.title)
            == ["Linear installation", "Operator identity", "An agent CLI with a route"])
    }
}
