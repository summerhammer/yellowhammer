import Domain
import SwiftUI

/// "Connect GitHub": the two ways to add a Code Hosting Connection — the gh CLI, acting as gh's active
/// account with no token held by Yellowhammer, and a Keychain token under an Operator-typed local name, pasted
/// or imported once from the gh CLI. Every button runs `yh` through ``CodeHostingConnectionsModel``; the token
/// field is emptied before the run starts, and no name is validated here.
struct CodeHostingConnectBlock: View {
    let model: CodeHostingConnectionsModel
    @State private var name: String
    @State private var token = ""

    init(model: CodeHostingConnectionsModel) {
        self.model = model
        _name = State(initialValue: model.suggestedKeychainName)
    }

    var body: some View {
        WizardBlock(title: "Connect GitHub") {
            VStack(alignment: .leading, spacing: 0) {
                gitHubCLIRow
                Divider()
                keychainTokenRows
                if let lines = model.connectFailure {
                    Divider()
                    SettingsFailureText(
                        text: lines.joined(separator: "\n"), identifier: "settings-code-hosting-connect-failure",
                        monospaced: true
                    )
                    .padding(12)
                }
                if !model.connectedMessage.isEmpty {
                    Divider()
                    WizardNote(text: model.connectedMessage.joined(separator: "\n"))
                        .textSelection(.enabled)
                        .padding(12)
                        .accessibilityIdentifier("settings-code-hosting-connected")
                }
            }
        }
    }

    // MARK: gh CLI

    private var gitHubCLIRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("gh CLI")
                Text(gitHubCLIDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings-code-hosting-gh-detail")
            }
            Spacer(minLength: 12)
            if model.running == .connect { ProgressView().controlSize(.small) }
            Button("Connect") { Task { await model.connectGitHubCLI() } }
                .disabled(model.gitHubCLIOffer?.available != true || model.isRunning)
                .accessibilityIdentifier("settings-code-hosting-connect-gh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var gitHubCLIDetail: String {
        if let offer = model.gitHubCLIOffer {
            if offer.available {
                return "Acts as gh\u{2019}s active account \(offer.login ?? ""). Yellowhammer holds no token."
            }
            return offer.reason ?? "The gh CLI is not available."
        }
        return model.reportFailure == nil ? "Checking\u{2026}" : "Not read."
    }

    // MARK: Keychain token

    private var keychainTokenRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keychain token")
            Text("A token Yellowhammer stores in the login Keychain under a local name you choose.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Local name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings-code-hosting-name")
            HStack(spacing: 8) {
                SecureField("GitHub token", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(storeToken)
                    .accessibilityIdentifier("settings-code-hosting-token-field")
                Button("Connect", action: storeToken)
                    .disabled(isNameEmpty || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.isRunning)
                    .accessibilityIdentifier("settings-code-hosting-token-store")
            }
            Button("Import from gh", action: importToken)
                .disabled(isNameEmpty || model.isRunning)
                .accessibilityIdentifier("settings-code-hosting-import-gh")
        }
        .padding(12)
    }

    private var isNameEmpty: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Hands the token to `yh` and empties the field before the run starts: the app keeps no copy.
    private func storeToken() {
        let value = token
        let localName = name
        token = ""
        Task {
            if await model.connectKeychainToken(name: localName, token: value) { name = model.suggestedKeychainName }
        }
    }

    private func importToken() {
        let localName = name
        token = ""
        Task {
            if await model.connectKeychainTokenFromGitHubCLI(name: localName) { name = model.suggestedKeychainName }
        }
    }
}
