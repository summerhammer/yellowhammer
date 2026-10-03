import Config
import Testing

@Suite("MachineConfiguration.removingLinearInstallation")
struct ConfigurationRemovingInstallationTests {
    private let text = """
        # machine file
        [board.linear.installations.alpha]
        credential = "keychain:linear-alpha"
        workspace = "ws-a"
        app_user = "app-a"
        operator = "user-a"

        # the second one
        [board.linear.installations.beta]
        credential = "keychain:linear-beta"
        workspace = "ws-b"
        app_user = "app-b"

        [github]
        credential = "keychain:github"

        """

    @Test("Removes only that table and keeps comments and sibling tables")
    func removesOnlyThatTable() throws {
        let updated = MachineConfiguration.removingLinearInstallation(named: "alpha", inFileText: text)
        #expect(!updated.contains("alpha"))
        #expect(updated.contains("# machine file"))
        #expect(updated.contains("# the second one"))
        #expect(updated.contains("[board.linear.installations.beta]"))
        #expect(updated.contains("[github]"))
        let machine = try MachineConfiguration.parse(updated, file: "config.toml")
        #expect(machine.linearInstallations.map(\.name) == ["beta"])
        #expect(!updated.contains("\n\n\n"))
    }

    @Test("Removes the last table in the file")
    func removesLastTable() throws {
        let updated = MachineConfiguration.removingLinearInstallation(named: "beta", inFileText: text)
        let machine = try MachineConfiguration.parse(updated, file: "config.toml")
        #expect(machine.linearInstallations.map(\.name) == ["alpha"])
        #expect(updated.contains("[github]"))
    }

    @Test("Unchanged when the entry is absent")
    func unchangedWhenAbsent() {
        #expect(MachineConfiguration.removingLinearInstallation(named: "gamma", inFileText: text) == text)
    }

    @Test("Applying it twice equals applying it once")
    func idempotent() {
        let once = MachineConfiguration.removingLinearInstallation(named: "alpha", inFileText: text)
        #expect(MachineConfiguration.removingLinearInstallation(named: "alpha", inFileText: once) == once)
    }
}
