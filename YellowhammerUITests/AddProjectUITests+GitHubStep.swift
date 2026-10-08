import Foundation
import XCTest

/// The Add Project wizard's GitHub step: a missing token is typed into the secure field, stored through
/// `yh setup connect-code-hosting github --token-stdin`, and checked again. Split from `AddProjectUITests` to keep both
/// under SwiftLint's length limits.
extension AddProjectUITests {
    /// The token the test types. It must appear in no argument vector the app ran.
    static let typedGitHubToken = "ghp_uitest_secret_token"

    func testStoringAMissingGitHubTokenSendsItOnlyOverStandardInput() throws {
        try launchApp(machine: Self.readyMachineTOML, githubMissing: true)
        let sheet = openAddProjectSheet()
        let step = element("setup-step-github")
        XCTAssertTrue(step.waitForExistence(timeout: 10))
        step.click()

        XCTAssertTrue(waitForText(of: element("github-credential-state"), containing: "Missing"))
        let field = app.secureTextFields["github-token-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText(Self.typedGitHubToken)
        let store = sheet.buttons["github-token-store"]
        XCTAssertTrue(store.isEnabled)
        store.click()

        XCTAssertTrue(waitForText(of: element("github-credential-state"), containing: "Stored"))
        XCTAssertTrue(
            waitForRecorded { $0.contains("connect-code-hosting github --token-stdin") }, "\(recordedArguments())"
        )
        for line in recordedArguments() {
            XCTAssertFalse(line.contains(Self.typedGitHubToken), "the token reached an argument vector")
        }
        // A stored token that works needs no field until the Operator asks to replace it.
        XCTAssertFalse(field.exists)
        XCTAssertTrue(element("github-replace-token").exists)
    }
}
