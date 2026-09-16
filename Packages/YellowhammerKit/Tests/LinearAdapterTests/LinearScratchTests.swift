import Domain
import Foundation
import LinearAdapter
import Security
import Testing

/// Against the real scratch Linear workspace — the done-condition a stub cannot prove. Opt-in only:
///
///     YH_LINEAR_SCRATCH_TESTS=1 YH_LINEAR_CLIENT_ID=… YH_LINEAR_PROJECT_ID=… \
///         swift test --package-path Packages/YellowhammerKit --filter LinearScratchTests
///
/// The client secret is read from the Keychain item behind `keychain:linear`. The Keychain is read with
/// `Security` directly, because this test target may import only its own adapter (MB2).
@Suite(
    "Linear scratch workspace (live)",
    .enabled(if: ProcessInfo.processInfo.environment["YH_LINEAR_SCRATCH_TESTS"] == "1")
)
struct LinearScratchTests {
    @Test("A token is obtained, identity is the registered application, and the Linear project's issues read")
    func liveRead() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let clientID = environment["YH_LINEAR_CLIENT_ID"], !clientID.isEmpty,
              let linearProjectID = environment["YH_LINEAR_PROJECT_ID"], !linearProjectID.isEmpty else {
            print("LinearScratchTests skipped: YH_LINEAR_CLIENT_ID or YH_LINEAR_PROJECT_ID is not set")
            return
        }
        guard let secret = Self.keychainSecret(account: "linear") else {
            print("LinearScratchTests skipped: no Keychain item for service dev.yellowhammer, account linear")
            return
        }

        let adapter = LinearAdapter(
            linearProjectID: linearProjectID,
            credentials: LinearCredentials(clientID: clientID, clientSecret: secret)
        )

        let identity = try await adapter.identity()
        #expect(!identity.id.rawValue.isEmpty)
        #expect(identity.name.localizedCaseInsensitiveContains("yellowhammer"), "resolved to \(identity.name)")

        let page = try await adapter.objects(updatedSince: nil, after: nil, pageSize: 50)
        for object in page.objects {
            #expect(!object.key.isEmpty)
            #expect(!object.workflowState.name.isEmpty)
        }
        #expect(await adapter.latestBudget?.requestsLimit != nil)
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
