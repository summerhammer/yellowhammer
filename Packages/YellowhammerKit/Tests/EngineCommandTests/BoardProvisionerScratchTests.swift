import Config
import Domain
import Engine
@testable import EngineCommand
import Foundation
import Security
import Testing

/// Against the real scratch Linear workspace — the done-condition a stub cannot prove. Opt-in only:
///
///     YH_LINEAR_SCRATCH_TESTS=1 YH_LINEAR_INSTALLATION=<local name> YH_LINEAR_PROJECT_ID=… \
///         swift test --package-path Packages/YellowhammerKit --filter BoardProvisionerScratchTests
///
/// Uses the token pair of the Board Connection named `YH_LINEAR_INSTALLATION`, already stored in the Keychain
/// item `linear-<name>` (P17.3/P17.4), via `BoardBinding` — no client id or secret of its own.
@Suite(
    "Linear provisioning (live)",
    .enabled(if: ProcessInfo.processInfo.environment["YH_LINEAR_SCRATCH_TESTS"] == "1")
)
struct BoardProvisionerScratchTests {
    @Test("Provisioning is idempotent across two runs")
    func provisioningIdempotent() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let linearProjectID = environment["YH_LINEAR_PROJECT_ID"], !linearProjectID.isEmpty else {
            print("BoardProvisionerScratchTests skipped: YH_LINEAR_PROJECT_ID is not set")
            return
        }
        guard let installation = Self.storedInstallation(environment) else {
            return
        }

        let machine = try MachineConfiguration.parse("""
            [board.linear.connections."\(installation)"]
            credential = "keychain:linear-\(installation)"
            workspace = "workspace-1"
            yellowhammer_identity = "app-user-1"

            [github]
            credential = "keychain:github"
            """, file: "config.toml")

        let project = try ProjectConfiguration.parse("""
            id = "yellowhammer"
            name = "Yellowhammer"
            board = { linear = { connection = "\(installation)", project = "\(linearProjectID)" } }
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

    /// The local name in `YH_LINEAR_INSTALLATION` when its Keychain item exists; nil, having printed why, otherwise.
    private static func storedInstallation(_ environment: [String: String]) -> String? {
        guard let installation = environment["YH_LINEAR_INSTALLATION"], !installation.isEmpty else {
            print("BoardProvisionerScratchTests skipped: YH_LINEAR_INSTALLATION is not set")
            return nil
        }
        guard keychainSecret(account: "linear-\(installation)") != nil else {
            print("BoardProvisionerScratchTests skipped: no Keychain item for service dev.yellowhammer, "
                + "account linear-\(installation)")
            return nil
        }
        return installation
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
