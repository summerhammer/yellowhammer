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

    @Test("A create replays as already applied, a comment posts, a description rewrites, and the issue archives")
    func liveWriting() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let oauthClientID = environment["YH_LINEAR_CLIENT_ID"], !oauthClientID.isEmpty,
              let linearProjectID = environment["YH_LINEAR_PROJECT_ID"], !linearProjectID.isEmpty else {
            print("liveWriting skipped: YH_LINEAR_CLIENT_ID or YH_LINEAR_PROJECT_ID is not set")
            return
        }
        guard let secret = Self.keychainSecret(account: "linear") else {
            print("liveWriting skipped: no Keychain item for service dev.yellowhammer, account linear")
            return
        }

        let adapter = LinearAdapter(
            linearProjectID: linearProjectID,
            credentials: LinearCredentials(clientID: oauthClientID, clientSecret: secret)
        )

        let scope = try await adapter.linearProject()
        let createClientID = UUID()
        let title = "yh outbox probe \(createClientID)"
        let draft = BoardIssueDraft(
            team: scope.teams[0].id, title: title,
            description: "<!-- yh:managed:start -->\n\n<!-- yh:managed:end -->"
        )

        let firstReceipt = try await adapter.createIssue(draft, clientID: createClientID)
        guard case .created(let issueID) = firstReceipt else {
            Issue.record("expected first create to be .created")
            return
        }

        // Replay the same create with the same clientID
        let replayReceipt = try await adapter.createIssue(draft, clientID: createClientID)
        #expect(replayReceipt == .alreadyApplied(issueID))

        // Create a comment
        let commentClientID = UUID()
        let commentReceipt = try await adapter.createComment(
            on: issueID, body: "Test comment", clientID: commentClientID
        )
        guard case .created = commentReceipt else {
            Issue.record("expected comment create to be .created")
            return
        }

        // Read the description
        let description = try await adapter.issueDescription(issueID)
        #expect(description.id == issueID)

        // Update the description
        var change = BoardIssueChange()
        change.description = "<!-- yh:managed:start -->\nUpdated\n<!-- yh:managed:end -->"
        let updated = try await adapter.updateIssue(issueID, change)
        #expect(updated.id == issueID)
        #expect(updated.description?.contains("Updated") ?? false)

        // Archive the issue
        try await adapter.archiveIssue(issueID)
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
