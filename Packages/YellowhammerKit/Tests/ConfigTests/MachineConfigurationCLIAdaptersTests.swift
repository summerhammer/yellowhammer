import Config
import Domain
import Foundation
import Testing

@Suite("Declaring a CLI Adapter")
struct MachineConfigurationCLIAdaptersTests {
    private func machine(adapters: [String], routes: [(String, [String])] = []) throws -> MachineConfiguration {
        MachineConfiguration(
            linearCredential: try editingCredential("keychain:linear"),
            gitHubCredential: try editingCredential("keychain:github"),
            cliAdapters: adapters.map { CLIAdapterDeclaration(name: $0) },
            routingTable: try routes.map { cli, fallbacks in
                RoutingEntry(
                    route: try editingRoute(cli, "sonnet"),
                    fallbacks: try fallbacks.map { try editingRoute($0, "sonnet") }
                )
            }
        )
    }

    @Test("declarableCLIAdapters is the registry minus the declared names, in registry order")
    func declarable() throws {
        #expect(try machine(adapters: []).declarableCLIAdapters == ["claude", "codex"])
        #expect(try machine(adapters: ["claude"]).declarableCLIAdapters == ["codex"])
        #expect(try machine(adapters: ["codex"]).declarableCLIAdapters == ["claude"])
        #expect(try machine(adapters: ["claude", "codex"]).declarableCLIAdapters.isEmpty)
    }

    @Test("declaring trims the executable and maps blank to nil")
    func declaringTrims() throws {
        let base = try machine(adapters: [])
        #expect(base.declaring(cliAdapter: "claude", executable: "").cliAdapters
            == [CLIAdapterDeclaration(name: "claude", executable: nil)])
        #expect(base.declaring(cliAdapter: "claude", executable: "   ").cliAdapters
            == [CLIAdapterDeclaration(name: "claude", executable: nil)])
        #expect(base.declaring(cliAdapter: "claude", executable: " /opt/bin/claude ").cliAdapters
            == [CLIAdapterDeclaration(name: "claude", executable: "/opt/bin/claude")])
    }

    @Test("declaring appends after the existing declarations")
    func declaringAppends() throws {
        let declared = try machine(adapters: ["claude"]).declaring(cliAdapter: "codex", executable: "")
        #expect(declared.cliAdapters.map(\.name) == ["claude", "codex"])
    }

    @Test("hasRouteToDeclaredCLI: none, route match, fallback-only match")
    func hasRoute() throws {
        #expect(try !machine(adapters: ["claude"]).hasRouteToDeclaredCLI)
        #expect(try !machine(adapters: [], routes: [("claude", [])]).hasRouteToDeclaredCLI)
        #expect(try machine(adapters: ["claude"], routes: [("claude", [])]).hasRouteToDeclaredCLI)
        #expect(try machine(adapters: ["codex"], routes: [("claude", ["codex"])]).hasRouteToDeclaredCLI)
        #expect(try !machine(adapters: ["codex"], routes: [("claude", [])]).hasRouteToDeclaredCLI)
    }

    @Test("A fresh-Mac machine file with no CLI and no routing loads, and declaring a CLI saves and reloads")
    func freshMacEndToEnd() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yellowhammer-declare-cli-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("projects"), withIntermediateDirectories: true
        )
        defer { cleanupEditingDirectory(directory) }
        let file = editingMachineFileURL(directory)
        let text = """
            [linear]
            credential = "keychain:linear"

            [github]
            credential = "keychain:github"
            """
        try text.write(to: file, atomically: true, encoding: .utf8)

        let configuration = try Configuration.load(directory: directory, reading: file, as: text)
        #expect(configuration.machine.cliAdapters.isEmpty)
        #expect(configuration.machine.routingTable.isEmpty)

        let edited = configuration.machine
            .declaring(cliAdapter: "claude", executable: "/opt/homebrew/bin/claude").renderedTOML
        try Configuration.save(edited, to: file, in: directory, replacing: text)

        let reloaded = try MachineConfiguration.load(contentsOf: file)
        #expect(reloaded.cliAdapters == [CLIAdapterDeclaration(name: "claude", executable: "/opt/homebrew/bin/claude")])
    }
}
