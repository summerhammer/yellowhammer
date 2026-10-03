import Config
import Domain
@testable import EngineCommand
import Foundation
import Synchronization
import Testing

private let twoInstallations = """
    # machine file
    [board.linear.installations.alpha]
    credential = "keychain:linear-alpha"
    workspace = "ws-a"
    app_user = "app-a"

    [board.linear.installations.beta]
    credential = "keychain:linear-beta"
    workspace = "ws-b"
    app_user = "app-b"

    [github]
    credential = "keychain:github"
    """

private final class RecordingDeleter: InstallationCredentialDeleter {
    private let storage = Mutex<[String]>([])
    private let failure: Bool

    init(failing: Bool = false) { failure = failing }

    var references: [String] { storage.withLock { $0 } }

    func delete(_ reference: CredentialReference) throws {
        storage.withLock { $0.append(reference.rawValue) }
        if failure { throw SetupError("keychain refused") }
    }
}

private func remove(
    _ name: String, directory: borrowing ConfigurationDirectory, deleter: RecordingDeleter = RecordingDeleter()
) throws -> (succeeded: Bool, lines: [String]) {
    let command = try #require(
        try ConfigRemoveInstallationCommand.parse([name]) as? ConfigRemoveInstallationCommand
    )
    let output = RecordingOutput()
    let home = FileManager.default.temporaryDirectory
        .appending(component: "yh-remove-home-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }
    do {
        try command.run(
            configurationDirectory: directory.url, homeDirectory: home,
            output: { output.record($0) }, credentials: deleter
        )
        return (true, output.lines)
    } catch {
        return (false, output.lines)
    }
}

@Suite("yh config remove-installation")
struct ConfigRemoveInstallationCommandTests {
    @Test("An unknown name is refused, naming it; nothing changes")
    func unknownName() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoInstallations)
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let deleter = RecordingDeleter()
        let result = try remove("gamma", directory: directory, deleter: deleter)
        #expect(!result.succeeded)
        #expect(result.lines.joined().contains("gamma"))
        #expect(deleter.references.isEmpty)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("An installation named by Projects is refused, listing their ids; config.toml and Keychain untouched")
    func namedByProjects() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoInstallations.replacingOccurrences(of: "alpha", with: "acme"))
        try directory.writeValidProjectFile(id: "zeta")
        try directory.writeValidProjectFile(id: "abc")
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let deleter = RecordingDeleter()
        let result = try remove("acme", directory: directory, deleter: deleter)
        #expect(!result.succeeded)
        let message = result.lines.joined()
        #expect(message.contains("abc, zeta"))
        #expect(message.contains("yh project remove abc")) // glossary:ignore GL001
        #expect(deleter.references.isEmpty)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("An undecodable Project file is refused, naming the file; untouched")
    func undecodableProject() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoInstallations)
        try directory.writeProjectFile(id: "broken", "this is = [not valid")
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let deleter = RecordingDeleter()
        let result = try remove("alpha", directory: directory, deleter: deleter)
        #expect(!result.succeeded)
        #expect(result.lines.joined().contains("broken.toml"))
        #expect(deleter.references.isEmpty)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("Success deletes the Keychain item, then the entry; the sibling stays and the file re-parses")
    func success() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoInstallations)
        let deleter = RecordingDeleter()
        let result = try remove("alpha", directory: directory, deleter: deleter)
        #expect(result.succeeded)
        #expect(deleter.references == ["keychain:linear-alpha"])
        let text = try String(contentsOf: directory.url.appending(component: "config.toml"), encoding: .utf8)
        #expect(text.contains("# machine file"))
        let machine = try MachineConfiguration.parse(text, file: "config.toml")
        #expect(machine.linearInstallations.map(\.name) == ["beta"])
        let message = result.lines.joined(separator: "\n")
        #expect(message.contains("stays installed in that Linear workspace"))
    }

    @Test("A Keychain delete failure is an error and config.toml is untouched")
    func keychainFailure() throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoInstallations)
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let result = try remove("alpha", directory: directory, deleter: RecordingDeleter(failing: true))
        #expect(!result.succeeded)
        #expect(result.lines.joined().contains("keychain refused"))
        #expect(try Data(contentsOf: file) == before)
    }
}
