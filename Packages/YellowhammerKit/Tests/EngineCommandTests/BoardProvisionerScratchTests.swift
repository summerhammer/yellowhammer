import Config
import Domain
import Engine
@testable import EngineCommand
import Foundation
import Security
import Testing

/// Against the real scratch Linear workspace — the done-condition a stub cannot prove. Opt-in only:
///
///     YH_LINEAR_SCRATCH_TESTS=1 YH_LINEAR_CLIENT_ID=… YH_LINEAR_PROJECT_ID=… \
///         swift test --package-path Packages/YellowhammerKit --filter BoardProvisionerScratchTests
@Suite(
    "Linear provisioning (live)",
    .enabled(if: ProcessInfo.processInfo.environment["YH_LINEAR_SCRATCH_TESTS"] == "1")
)
struct BoardProvisionerScratchTests {
    @Test("Provisioning is idempotent across two runs")
    func provisioningIdempotent() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let clientID = environment["YH_LINEAR_CLIENT_ID"], !clientID.isEmpty,
              let linearProjectID = environment["YH_LINEAR_PROJECT_ID"], !linearProjectID.isEmpty else {
            print("BoardProvisionerScratchTests skipped: YH_LINEAR_CLIENT_ID or YH_LINEAR_PROJECT_ID is not set")
            return
        }
        guard let secret = Self.keychainSecret(account: "linear") else {
            print("BoardProvisionerScratchTests skipped: no Keychain item for service dev.yellowhammer, account linear")
            return
        }

        let machine = try MachineConfiguration.parse("""
            [linear]
            credential = "keychain:linear"
            client_id = "\(clientID)"

            [github]
            credential = "keychain:github"
            """, file: "config.toml")

        let project = try ProjectConfiguration.parse("""
            id = "yellowhammer"
            name = "Yellowhammer"
            linear_project = "\(linearProjectID)"
            spec_source = "~/Developer/yellowhammer-spec"

            [[repos]]
            name = "backend"
            path = "~/Developer/yellowhammer-backend"
            role = "backend"
            check = "swift test"
            """, file: "yellowhammer.toml")

        let provisioning = try BoardBinding.provisioning(machine: machine, project: project)

        // First run
        let report1 = try await BoardProvisioner.provision(
            using: provisioning,
            projectName: project.name,
            createIn: nil
        )
        print("First run: \(report1.changes.count) changes")

        // Second run (should be idempotent)
        let report2 = try await BoardProvisioner.provision(
            using: provisioning,
            projectName: project.name,
            createIn: nil
        )
        print("Second run: \(report2.changes.count) changes")

        #expect(report2.isChanged == false, "Second run should not change anything")
        // A collision is reported again, never resolved by overwriting it.
        #expect(report1.collisions.map(\.subject) == report2.collisions.map(\.subject))
        print(report2)
    }

    private static func keychainSecret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.yellowhammer",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
