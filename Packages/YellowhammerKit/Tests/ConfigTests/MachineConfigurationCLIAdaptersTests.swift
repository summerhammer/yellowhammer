import Config
import Domain
import Foundation
import Testing

@Suite("Declaring a CLI Adapter")
struct MachineConfigurationCLIAdaptersTests {
    private func machine(adapters: [String], routes: [(String, [String])] = []) throws -> MachineConfiguration {
        MachineConfiguration(
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
        #expect(try machine(adapters: []).declarableCLIAdapters == ["claude", "codex", "agy"])
        #expect(try machine(adapters: ["claude"]).declarableCLIAdapters == ["codex", "agy"])
        #expect(try machine(adapters: ["codex"]).declarableCLIAdapters == ["claude", "agy"])
        #expect(try machine(adapters: ["claude", "codex", "agy"]).declarableCLIAdapters.isEmpty)
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

    @Test("removing drops only the named declaration and keeps the rest in order")
    func removingDropsTheName() throws {
        let removed = try machine(adapters: ["claude", "codex"]).removing(cliAdapter: "claude")
        #expect(removed.cliAdapters.map(\.name) == ["codex"])
        #expect(try machine(adapters: ["codex"]).removing(cliAdapter: "claude").cliAdapters.map(\.name) == ["codex"])
    }

    @Test("baseRoutingTableNames: route match, fallback-only match, no match")
    func baseRoutingTableNames() throws {
        let configured = try machine(adapters: ["claude", "codex"], routes: [("claude", ["codex"])])
        #expect(configured.baseRoutingTableNames(cliAdapter: "claude"))
        #expect(configured.baseRoutingTableNames(cliAdapter: "codex"))
        #expect(try !machine(adapters: ["claude", "codex"], routes: [("claude", [])])
            .baseRoutingTableNames(cliAdapter: "codex"))
    }

    @Test("Removing a CLI a base route names is refused on save, and the file is kept")
    func removingARoutedCLIIsRefused() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yellowhammer-declare-cli-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("projects"), withIntermediateDirectories: true
        )
        defer { cleanupEditingDirectory(directory) }
        let file = editingMachineFileURL(directory)
        let text = try machine(adapters: ["claude", "codex"], routes: [("claude", [])]).renderedTOML
        try text.write(to: file, atomically: true, encoding: .utf8)
        let loaded = try Configuration.load(directory: directory, reading: file, as: text).machine

        #expect(throws: ConfigurationEditError.self) {
            try Configuration.save(
                loaded.removing(cliAdapter: "claude").renderedTOML, to: file, in: directory, replacing: text
            )
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == text)

        try Configuration.save(
            loaded.removing(cliAdapter: "codex").renderedTOML, to: file, in: directory, replacing: text
        )
        #expect(try MachineConfiguration.load(contentsOf: file).cliAdapters.map(\.name) == ["claude"])
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

    @Test("With no config.toml at all, declaring a CLI on the unconfigured machine creates the file and its directory")
    func declaringCreatesAMissingMachineFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yellowhammer-declare-cli-tests-\(UUID().uuidString)")
        defer { cleanupEditingDirectory(directory) }
        let file = editingMachineFileURL(directory)

        let edited = MachineConfiguration.unconfigured
            .declaring(cliAdapter: "claude", executable: "").renderedTOML
        try Configuration.save(edited, to: file, in: directory, replacing: nil)

        let reloaded = try MachineConfiguration.load(contentsOf: file)
        #expect(reloaded.cliAdapters == [CLIAdapterDeclaration(name: "claude")])
        #expect(reloaded.gitHubCredential.rawValue == MachineConfiguration.defaultGitHubCredential)
        #expect(reloaded.linearInstallations.isEmpty)
    }

    @Test("A save that expected no config.toml refuses, and keeps the file, when one appeared in the meantime")
    func creatingRefusesWhenTheFileAppeared() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yellowhammer-declare-cli-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { cleanupEditingDirectory(directory) }
        let file = editingMachineFileURL(directory)
        let handWritten = """
            [github]
            credential = "keychain:github"
            """
        try handWritten.write(to: file, atomically: true, encoding: .utf8)

        let edited = MachineConfiguration.unconfigured
            .declaring(cliAdapter: "claude", executable: "").renderedTOML
        #expect(throws: ConfigurationEditError.changedOnDisk(file: file.path(percentEncoded: false))) {
            try Configuration.save(edited, to: file, in: directory, replacing: nil)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == handWritten)
    }

    @Test("An executable that cannot run is named, with why; none at all is looked up on PATH")
    func executableProblem() throws {
        let directory = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let runnable = directory.appending(component: "claude").path(percentEncoded: false)
        let plain = directory.appending(component: "notes").path(percentEncoded: false)
        #expect(FileManager.default.createFile(atPath: runnable, contents: Data("#!/bin/sh\n".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runnable)
        #expect(FileManager.default.createFile(atPath: plain, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain)
        let missing = directory.appending(component: "claud").path(percentEncoded: false)

        #expect(CLIAdapterDeclaration(name: "claude").executableProblem == nil)
        #expect(CLIAdapterDeclaration(name: "claude", executable: runnable).executableProblem == nil)
        let typo = try #require(CLIAdapterDeclaration(name: "claude", executable: missing).executableProblem)
        #expect(typo.contains("No file at \(missing)"))
        let notExecutable = try #require(CLIAdapterDeclaration(name: "claude", executable: plain).executableProblem)
        #expect(notExecutable.contains("not executable"))
        let relative = try #require(CLIAdapterDeclaration(name: "claude", executable: "bin/claude").executableProblem)
        #expect(relative.contains("absolute path"))
    }

    @Test("A route counts as runnable only when it names a CLI whose executable can run")
    func runnableRoute() throws {
        var configuration = try machine(adapters: ["claude", "agy"], routes: [("claude", [])])
        configuration.cliAdapters[0].executable = "/nonexistent/claud"
        #expect(configuration.hasRouteToDeclaredCLI)
        #expect(!configuration.hasRouteToRunnableCLI)
        configuration.routingTable = try machine(adapters: [], routes: [("claude", ["agy"])]).routingTable
        #expect(configuration.hasRouteToRunnableCLI)
    }
}
