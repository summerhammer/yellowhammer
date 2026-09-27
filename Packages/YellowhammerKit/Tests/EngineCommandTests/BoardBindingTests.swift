import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

/// `BoardBinding` never eagerly reads the Keychain (P17.4): construction always succeeds, and a missing
/// or unreadable Installation token pair only ever surfaces from the first Linear call the adapter
/// makes, as `.notAuthenticated` naming the setup fix (`LinearInstallationTokenSource`'s own job, P17.3).
struct BoardBindingTests {
    private func makeMachineAndProject(credential: String) throws -> (MachineConfiguration, ProjectConfiguration) {
        let machine = try MachineConfiguration.parse("""
            [linear]
            credential = "\(credential)"

            [github]
            credential = "keychain:github"
            """, file: "config.toml")
        let project = try ProjectConfiguration.parse("""
            id = "yellowhammer"
            name = "Yellowhammer"
            linear_project = "7f1c2d9e-3b4a-4c5d-8e6f-0a1b2c3d4e5f"
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

        // No `try`: `board`/`provisioning`/`actBoard` are non-throwing since P17.4.
        _ = BoardBinding.board(machine: machine, project: project)
        _ = BoardBinding.provisioning(machine: machine, project: project)
        _ = BoardBinding.actBoard(machine: machine, project: project)
    }

    @Test("A missing Installation token pair fails only the first Linear call, as notAuthenticated")
    func missingInstallationFailsFirstCall() async throws {
        let account = "yh-test-absent-\(UUID().uuidString)"
        let (machine, project) = try makeMachineAndProject(credential: "keychain:\(account)")
        // A lock file under a throwaway temp home: this test never installs anything, so the lock is
        // never contended, but binding still needs a real, writable path to open.
        let homeDirectory = FileManager.default.temporaryDirectory
            .appending(component: "yh-binding-home-\(UUID().uuidString)", directoryHint: .isDirectory)

        let board = BoardBinding.board(machine: machine, project: project, homeDirectory: homeDirectory)

        do {
            _ = try await board.identity()
            Issue.record("expected the first Linear call to fail")
        } catch .notAuthenticated(let message) {
            #expect(message.contains("re-run the Linear step of yh setup"))
        } catch {
            Issue.record("expected notAuthenticated, got \(error)")
        }
    }
}
