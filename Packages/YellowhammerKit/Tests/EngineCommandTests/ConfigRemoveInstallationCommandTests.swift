import ArgumentParser
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

/// A presence store that answers from a fixed `CredentialPresence` and counts every ask.
private final class CountingPresence: SetupCredentialStore {
    private let asked = Mutex(0)
    private let answer: CredentialPresence

    init(_ answer: CredentialPresence) { self.answer = answer }

    var askCount: Int { asked.withLock { $0 } }

    func secret(for reference: CredentialReference) -> String? {
        presence(of: reference) == .present ? "secret" : nil
    }

    func presence(of reference: CredentialReference) -> CredentialPresence {
        asked.withLock { $0 += 1 }
        return answer
    }
}

private struct RemoveResult {
    let succeeded: Bool
    let lines: [String]
    let error: (any Error)?
    let binds: Int
    let presenceAsks: Int
    let prompts: [String]
}

private func remove(
    _ name: String, flags: [String] = [], directory: borrowing ConfigurationDirectory,
    deleter: RecordingDeleter = RecordingDeleter(), presence: CountingPresence = CountingPresence(.present),
    board: FakeProvisioningBoard? = nil, answers: [String?] = []
) async throws -> RemoveResult {
    let command = try #require(
        try ConfigRemoveInstallationCommand.parse([name] + flags) as? ConfigRemoveInstallationCommand
    )
    let output = RecordingOutput()
    let binds = Mutex(0)
    let console = ScriptedConsole(answers: answers)
    let fake = board ?? FakeProvisioningBoard(project: nil)
    let home = FileManager.default.temporaryDirectory
        .appending(component: "yh-remove-home-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: home) }
    do {
        try await command.run(
            configurationDirectory: directory.url, homeDirectory: home,
            output: { output.record($0) }, credentials: deleter, presence: presence,
            bindProvisioning: { _, _ in
                binds.withLock { $0 += 1 }
                return fake
            },
            console: console
        )
        return RemoveResult(
            succeeded: true, lines: output.lines, error: nil, binds: binds.withLock { $0 },
            presenceAsks: presence.askCount, prompts: console.prompts
        )
    } catch {
        return RemoveResult(
            succeeded: false, lines: output.lines, error: error, binds: binds.withLock { $0 },
            presenceAsks: presence.askCount, prompts: console.prompts
        )
    }
}

@Suite("yh config remove-installation")
struct ConfigRemoveInstallationCommandTests {
    @Test("An unknown name is refused, naming it; nothing changes")
    func unknownName() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoInstallations)
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let deleter = RecordingDeleter()
        let result = try await remove("gamma", directory: directory, deleter: deleter)
        #expect(!result.succeeded)
        #expect(result.lines.joined().contains("gamma"))
        #expect(deleter.references.isEmpty)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("An installation named by Projects is refused, listing their ids; config.toml and Keychain untouched")
    func namedByProjects() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoInstallations.replacingOccurrences(of: "alpha", with: "acme"))
        try directory.writeValidProjectFile(id: "zeta")
        try directory.writeValidProjectFile(id: "abc")
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let deleter = RecordingDeleter()
        let result = try await remove("acme", directory: directory, deleter: deleter)
        #expect(!result.succeeded)
        let message = result.lines.joined()
        #expect(message.contains("abc, zeta"))
        #expect(message.contains("yh project remove abc")) // glossary:ignore GL001
        #expect(message.contains("--orphan-projects"))
        #expect(deleter.references.isEmpty)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("An undecodable Project file is refused, naming the file; untouched")
    func undecodableProject() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoInstallations)
        try directory.writeProjectFile(id: "broken", "this is = [not valid")
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let deleter = RecordingDeleter()
        let result = try await remove("alpha", directory: directory, deleter: deleter)
        #expect(!result.succeeded)
        #expect(result.lines.joined().contains("broken.toml"))
        #expect(deleter.references.isEmpty)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test("Success deletes the Keychain item, then the entry; the sibling stays and the file re-parses")
    func success() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoInstallations)
        let deleter = RecordingDeleter()
        let result = try await remove("alpha", directory: directory, deleter: deleter)
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
    func keychainFailure() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoInstallations)
        let file = directory.url.appending(component: "config.toml")
        let before = try Data(contentsOf: file)
        let result = try await remove("alpha", directory: directory, deleter: RecordingDeleter(failing: true))
        #expect(!result.succeeded)
        #expect(result.lines.joined().contains("keychain refused"))
        #expect(try Data(contentsOf: file) == before)
    }

    // MARK: - --orphan-projects (OQ121)

    /// `acme` is named by Projects `abc` and `zeta`; its Keychain item and board are the knobs.
    private func orphanDirectory() throws -> ConfigurationDirectory {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoInstallations.replacingOccurrences(of: "alpha", with: "acme"))
        try directory.writeValidProjectFile(id: "zeta")
        try directory.writeValidProjectFile(id: "abc")
        return directory
    }

    private func configText(_ directory: borrowing ConfigurationDirectory) throws -> Data {
        try Data(contentsOf: directory.url.appending(component: "config.toml"))
    }

    @Test("Keychain item absent: removed, Projects left naming it, with no live call")
    func orphanKeychainAbsent() async throws {
        let directory = try orphanDirectory()
        let deleter = RecordingDeleter()
        let result = try await remove(
            "acme", flags: ["--orphan-projects", "--yes"], directory: directory, deleter: deleter,
            presence: CountingPresence(.absent)
        )
        #expect(result.succeeded)
        #expect(result.binds == 0)
        #expect(deleter.references == ["keychain:linear-acme"])
        let text = try String(contentsOf: directory.url.appending(component: "config.toml"), encoding: .utf8)
        #expect(try MachineConfiguration.parse(text, file: "config.toml").linearInstallations.map(\.name) == ["beta"])
        // A strict load now refuses the Projects as naming a missing installation.
        let strict = try Configuration.load(directory: directory.url)
        #expect(Set(strict.invalidProjects.map { $0.file.split(separator: "/").last.map(String.init) ?? "" })
            == ["abc.toml", "zeta.toml"])
        #expect(strict.projects.isEmpty)
        let report = result.lines.joined(separator: "\n")
        #expect(report.contains("Installation acme removed"))
        #expect(report.contains("abc, zeta"))
        #expect(report.contains("yh project remove abc")) // glossary:ignore GL001
        #expect(report.contains("yh project remove zeta")) // glossary:ignore GL001
        #expect(report.contains("stays installed in that Linear workspace"))
        #expect(report.contains("yh setup --installation-name acme"))
    }

    @Test("Present and Linear refuses it: removed")
    func orphanLinearRefused() async throws {
        let directory = try orphanDirectory()
        let board = FakeProvisioningBoard(project: nil)
        await board.refuseWorkspaceMembersNext(.notAuthenticated("revoked"))
        let deleter = RecordingDeleter()
        let result = try await remove(
            "acme", flags: ["--orphan-projects", "--yes"], directory: directory, deleter: deleter, board: board
        )
        #expect(result.succeeded)
        #expect(result.binds == 1)
        #expect(deleter.references == ["keychain:linear-acme"])
    }

    @Test("Present and Linear unreachable: refused, nothing deleted, names the case")
    func orphanLinearUnreachable() async throws {
        let directory = try orphanDirectory()
        let before = try configText(directory)
        let board = FakeProvisioningBoard(project: nil)
        await board.refuseWorkspaceMembersNext(.unreachable("timed out"))
        let deleter = RecordingDeleter()
        let result = try await remove(
            "acme", flags: ["--orphan-projects", "--yes"], directory: directory, deleter: deleter, board: board
        )
        #expect(!result.succeeded)
        #expect(result.error is ExitCode)
        #expect(result.lines.joined().contains("Linear could not be reached"))
        #expect(result.lines.joined().contains("retry"))
        #expect(deleter.references.isEmpty)
        #expect(try configText(directory) == before)
    }

    @Test("Any other Linear error is not a refusal: refused, nothing deleted")
    func orphanLinearOtherError() async throws {
        let directory = try orphanDirectory()
        let board = FakeProvisioningBoard(project: nil)
        await board.refuseWorkspaceMembersNext(.forbidden("no"))
        let deleter = RecordingDeleter()
        let result = try await remove(
            "acme", flags: ["--orphan-projects", "--yes"], directory: directory, deleter: deleter, board: board
        )
        #expect(!result.succeeded)
        #expect(result.lines.joined().contains("could not confirm"))
        #expect(deleter.references.isEmpty)
    }

    @Test("Unreadable Keychain: refused with no live call, nothing deleted")
    func orphanKeychainUnreadable() async throws {
        let directory = try orphanDirectory()
        let before = try configText(directory)
        let deleter = RecordingDeleter()
        let result = try await remove(
            "acme", flags: ["--orphan-projects", "--yes"], directory: directory, deleter: deleter,
            presence: CountingPresence(.unreadable("interaction not allowed"))
        )
        #expect(!result.succeeded)
        #expect(result.binds == 0)
        #expect(result.lines.joined().contains("keychain unreadable"))
        #expect(deleter.references.isEmpty)
        #expect(try configText(directory) == before)
    }

    @Test("A healthy authorization: refused, nothing deleted")
    func orphanAuthorized() async throws {
        let directory = try orphanDirectory()
        let before = try configText(directory)
        let board = await makeBoard(members: [operatorMember])
        let deleter = RecordingDeleter()
        let result = try await remove(
            "acme", flags: ["--orphan-projects", "--yes"], directory: directory, deleter: deleter, board: board
        )
        #expect(!result.succeeded)
        #expect(result.lines.joined().contains("authorization is healthy"))
        #expect(deleter.references.isEmpty)
        #expect(try configText(directory) == before)
    }

    @Test("The flag with no Project naming the installation is a usage error before any probe")
    func orphanNothingToOrphan() async throws {
        let directory = ConfigurationDirectory()
        try directory.writeMachineFile(twoInstallations)
        let presence = CountingPresence(.absent)
        let deleter = RecordingDeleter()
        let result = try await remove(
            "alpha", flags: ["--orphan-projects", "--yes"], directory: directory, deleter: deleter,
            presence: presence
        )
        #expect(!result.succeeded)
        let usage = try #require(result.error as? ValidationError)
        #expect(usage.message.contains("nothing to orphan"))
        #expect(usage.message.contains("yh config remove-installation alpha"))
        #expect(result.binds == 0)
        #expect(presence.askCount == 0)
        #expect(deleter.references.isEmpty)
    }

    @Test("An undecodable Project file with the flag is refused, naming the file, before any probe")
    func orphanUndecodable() async throws {
        let directory = try orphanDirectory()
        try directory.writeProjectFile(id: "broken", "this is = [not valid")
        let presence = CountingPresence(.absent)
        let deleter = RecordingDeleter()
        let result = try await remove(
            "acme", flags: ["--orphan-projects", "--yes"], directory: directory, deleter: deleter,
            presence: presence
        )
        #expect(!result.succeeded)
        #expect(result.lines.joined().contains("broken.toml"))
        #expect(presence.askCount == 0)
        #expect(deleter.references.isEmpty)
    }

    @Test("A declined confirmation removes nothing; the prompt and the five items were shown")
    func orphanDeclined() async throws {
        let directory = try orphanDirectory()
        let before = try configText(directory)
        let deleter = RecordingDeleter()
        let result = try await remove(
            "acme", flags: ["--orphan-projects"], directory: directory, deleter: deleter,
            presence: CountingPresence(.absent), answers: ["n"]
        )
        #expect(!result.succeeded)
        #expect(result.error is ExitCode)
        #expect(result.prompts == ["Remove installation acme anyway? [y/N] "])
        let shown = result.lines.joined(separator: "\n")
        #expect(shown.contains("abc, zeta"))
        #expect(shown.contains("yh project remove abc")) // glossary:ignore GL001
        #expect(shown.contains("stays installed in that Linear workspace"))
        #expect(shown.contains("--installation-name acme"))
        #expect(deleter.references.isEmpty)
        #expect(try configText(directory) == before)
    }

    @Test("EOF at the confirmation removes nothing; a y answer removes")
    func orphanEOFAndYes() async throws {
        let eofDirectory = try orphanDirectory()
        let eof = try await remove(
            "acme", flags: ["--orphan-projects"], directory: eofDirectory, presence: CountingPresence(.absent),
            answers: [nil]
        )
        #expect(!eof.succeeded)

        let yesDirectory = try orphanDirectory()
        let deleter = RecordingDeleter()
        let yes = try await remove(
            "acme", flags: ["--orphan-projects"], directory: yesDirectory, deleter: deleter,
            presence: CountingPresence(.absent), answers: ["y"]
        )
        #expect(yes.succeeded)
        #expect(deleter.references == ["keychain:linear-acme"])
    }

    @Test("--yes without --orphan-projects is a usage error")
    func yesNeedsOrphanProjects() {
        #expect(throws: (any Error).self) {
            try ConfigRemoveInstallationCommand.parse(["alpha", "--yes"])
        }
    }
}
