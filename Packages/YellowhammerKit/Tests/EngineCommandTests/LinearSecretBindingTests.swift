import Config
import Domain
@testable import EngineCommand
import Foundation
import Testing

@Test("A missing Linear client secret in the Keychain is refused with a clear error")
func missingLinearSecretIsRefused() throws {
    let account = "yh-test-absent-\(UUID().uuidString)"
    let machine = try MachineConfiguration.parse("""
        [linear]
        credential = "keychain:\(account)"
        client_id = "yellowhammer-client-id"

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

    do {
        _ = try BoardBinding.board(machine: machine, project: project)
        Issue.record("expected the binding to fail")
    } catch {
        #expect(error.credential.rawValue == "keychain:\(account)")
        #expect(error.description.contains("keychain:\(account)"))
        #expect(error.description.contains("could not be read"))
    }
}
