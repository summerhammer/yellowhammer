import SwiftUI

/// GitHub's section of the Code Hosting pane: one card per Code Hosting Connection, then the way to connect
/// another. Everything GitHub-specific in Code Hosting is here or in the views it draws, so another Code
/// Hosting service's section is a sibling of this one.
struct GitHubCodeHostingSection: View {
    let model: CodeHostingConnectionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GitHub").font(.headline)
            if let loadFailure = model.loadFailure {
                SettingsFailureText(text: loadFailure, identifier: "settings-code-hosting-load-failure")
            }
            if let lines = model.reportFailure {
                SettingsFailureText(
                    text: lines.joined(separator: "\n"), identifier: "settings-code-hosting-report-failure",
                    monospaced: true
                )
            }
            if model.connections.isEmpty, model.loadFailure == nil {
                Text("No GitHub Code Hosting Connection is connected yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.connections) { connection in
                CodeHostingConnectionCard(model: model, connection: connection)
            }
            if !model.removalMessage.isEmpty {
                WizardNote(text: model.removalMessage.joined(separator: "\n"))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings-code-hosting-removed")
            }
            CodeHostingConnectBlock(model: model)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-code-hosting-section")
    }
}

/// The Code Hosting services Yellowhammer does not support yet: said once, naming none, with nothing to press.
struct CodeHostingUnsupportedGroup: View {
    var body: some View {
        WizardBlock {
            Text("Other Code Hosting services are not yet supported.")
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("settings-code-hosting-unsupported")
        }
    }
}
