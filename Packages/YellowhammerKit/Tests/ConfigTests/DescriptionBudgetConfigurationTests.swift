import Config
import Domain
import Testing

struct DescriptionBudgetConfigurationTests {
    private func machineFile(budgetLine: String?) -> String {
        """
        [board.linear.connections.acme]
        credential = "keychain:linear-acme"
        workspace = "workspace-1"
        yellowhammer_identity = "app-user-1"
        \(budgetLine ?? "")

        [code_hosting.github.connections.github]
        type = "keychain"
        credential = "keychain:github"
        """
    }

    private func budget(in text: String) throws -> Int? {
        try MachineConfiguration.parse(text, file: "c.toml").linearInstallations.first?.descriptionBudget
    }

    private let limit = BoardDescriptionLimit(maximum: 250_000, unit: .utf16CodeUnits)

    @Test("A description_budget decodes; an absent one is nil")
    func decodes() throws {
        let set = try MachineConfiguration.parse(machineFile(budgetLine: "description_budget = 50000"), file: "c.toml")
        #expect(set.linearInstallations.first?.descriptionBudget == 50_000)
        let unset = try MachineConfiguration.parse(machineFile(budgetLine: nil), file: "c.toml")
        #expect(unset.linearInstallations.first?.descriptionBudget == nil)
    }

    @Test("A value of 0 is refused at load as not positive, on its own line")
    func zeroRefusedAtLoad() {
        do {
            _ = try MachineConfiguration.parse(machineFile(budgetLine: "description_budget = 0"), file: "c.toml")
            Issue.record("expected 0 to be refused")
        } catch {
            #expect(error.reason == .notPositive(0))
            #expect(error.key == "board.linear.connections.acme.description_budget")
            #expect(error.line == 5)
        }
    }

    @Test("A value above the board's ceiling loads, then is refused naming the ceiling and its own line")
    func aboveCeilingRefusedWithBoardLimit() throws {
        let machine = try MachineConfiguration.parse(
            machineFile(budgetLine: "description_budget = 225001"), file: "c.toml"
        )
        let installation = try #require(machine.linearInstallations.first)
        do {
            _ = try installation.descriptionBudget(limit: limit)
            Issue.record("expected 225001 to be refused")
        } catch {
            #expect(error.file == "c.toml")
            #expect(error.line == 5)
            #expect(error.key == "board.linear.connections.acme.description_budget")
            #expect(error.reason == .aboveDescriptionBudgetCeiling(value: 225_001, ceiling: 225_000, limit: limit))
            #expect(error.description.contains("must be at most 225000"))
        }
    }

    @Test("The budget resolves to the default when unset and to the value when set")
    func resolves() throws {
        let unset = try MachineConfiguration.parse(machineFile(budgetLine: nil), file: "c.toml")
        #expect(try unset.linearInstallations[0].descriptionBudget(limit: limit).value == 10_000)
        let set = try MachineConfiguration.parse(machineFile(budgetLine: "description_budget = 225000"), file: "c.toml")
        #expect(try set.linearInstallations[0].descriptionBudget(limit: limit).value == 225_000)
    }

    @Test("The key survives the full render and the in-place edits")
    func roundTrip() throws {
        let credential = try #require(CredentialReference("keychain:linear-acme"))
        let installation = LinearInstallation(
            name: "acme", credential: credential, workspace: BoardObjectID(rawValue: "workspace-1"),
            appUser: BoardObjectID(rawValue: "app-user-1"), descriptionBudget: 42_000
        )
        let machine = MachineConfiguration(linearInstallations: [installation], cliAdapters: [], routingTable: [])
        let rendered = machine.renderedTOML
        #expect(rendered.contains("description_budget = 42000"))
        #expect(try MachineConfiguration.parse(rendered, file: "c.toml") == machine)

        // A re-connect carries no budget of its own: the key already in the file stays.
        var reconnected = installation
        reconnected.descriptionBudget = nil
        let kept = MachineConfiguration.settingLinearInstallation(reconnected, inFileText: rendered)
        #expect(try budget(in: kept) == 42_000)

        // One that carries a budget replaces the line in place, and a new entry is written with it.
        var changed = installation
        changed.descriptionBudget = 7
        let replaced = MachineConfiguration.settingLinearInstallation(changed, inFileText: rendered)
        #expect(try budget(in: replaced) == 7)
        let appended = MachineConfiguration.settingLinearInstallation(installation, inFileText: "")
        #expect(try budget(in: appended) == 42_000)
    }
}
