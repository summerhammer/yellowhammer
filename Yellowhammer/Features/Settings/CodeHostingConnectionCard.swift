import Domain
import SwiftUI

/// One card of the Code Hosting pane's connections: an icon and the connection's label as its headline, its
/// facts laid out under it — local name, type, Code Hosting identity, the Projects that select it — then
/// `yh`'s reason when it refuses the connection, and the things Settings does to it: replace a Keychain
/// token, remove. Every identifier is suffixed with the connection's local name and sits on a leaf element.
struct CodeHostingConnectionCard: View {
    let model: CodeHostingConnectionsModel
    let connection: CodeHostingConnectionsModel.Connection
    @State private var isConfirmingRemoval = false
    @State private var isReplacing = false
    @State private var token = ""

    private var name: String { connection.name }

    var body: some View {
        SettingsCard(hasProblem: live?.state == .refused) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: DomainSymbol.codeHostingConnection).foregroundStyle(.accent)
                    .accessibilityHidden(true)
                Text(model.label(for: connection))
                    .font(.headline)
                    .accessibilityIdentifier("settings-code-hosting-connection-\(name)")
                Spacer()
                removeButton
            }
            if live?.state == .refused {
                Text(live?.reason ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings-code-hosting-status-\(name)")
            }
            if let lines = model.removalFailures[name] {
                SettingsFailureText(
                    text: lines.joined(separator: "\n"), identifier: "settings-code-hosting-remove-failure-\(name)",
                    monospaced: true
                )
            }
            details
            if connection.kind == .keychain {
                Divider()
                replacement
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-code-hosting-row-\(name)")
        .confirmationDialog(
            "Remove the Code Hosting Connection \(model.label(for: connection))?", isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { Task { await model.remove(name) } }
        } message: {
            Text(
                "A Keychain token connection\u{2019}s Keychain item is deleted with it. The gh CLI\u{2019}s own "
                    + "login is never changed."
            )
        }
    }

    private var live: CodeHostingConnectionsReport.Connection? { model.live[name] }

    private var removeButton: some View {
        Button("Remove\u{2026}", systemImage: "trash", role: .destructive) { isConfirmingRemoval = true }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(model.isRunning)
            .help("Remove \(model.label(for: connection)) from this Mac")
            .accessibilityIdentifier("settings-code-hosting-remove-\(name)")
    }

    // MARK: Facts

    private var details: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Local name").foregroundStyle(.secondary)
                Text(name).font(.callout.monospaced()).textSelection(.enabled)
            }
            GridRow {
                Text("Type").foregroundStyle(.secondary)
                Text(connection.kind == .gh ? "gh CLI" : "Keychain token")
                    .accessibilityIdentifier("settings-code-hosting-type-\(name)")
            }
            GridRow {
                Text("Code Hosting identity").foregroundStyle(.secondary)
                Text(live?.identity ?? "Not read")
                    .font(live?.identity == nil ? .callout : .callout.monospaced())
                    .foregroundStyle(live?.identity == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings-code-hosting-identity-\(name)")
            }
            GridRow {
                Text("Projects").foregroundStyle(.secondary)
                Text(connection.projects.isEmpty
                    ? "No Project uses this connection." : connection.projects.joined(separator: ", "))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settings-code-hosting-projects-\(name)")
            }
        }
        .font(.callout)
    }

    // MARK: Replacing a Keychain token

    @ViewBuilder private var replacement: some View {
        if let lines = model.replaceFailures[name] {
            SettingsFailureText(
                text: lines.joined(separator: "\n"), identifier: "settings-code-hosting-replace-failure-\(name)",
                monospaced: true
            )
        }
        if let lines = model.replacedMessages[name], !isReplacing {
            WizardNote(text: lines.joined(separator: "\n"))
                .textSelection(.enabled)
                .accessibilityIdentifier("settings-code-hosting-replaced-\(name)")
        }
        if isReplacing {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SecureField("GitHub token", text: $token)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(replaceByPaste)
                        .accessibilityIdentifier("settings-code-hosting-replace-field-\(name)")
                    Button("Replace", action: replaceByPaste)
                        .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isRunning)
                        .accessibilityIdentifier("settings-code-hosting-replace-store-\(name)")
                }
                HStack(spacing: 8) {
                    Button("Import from gh", action: replaceByImport)
                        .disabled(model.isRunning)
                        .accessibilityIdentifier("settings-code-hosting-replace-import-\(name)")
                    Button("Cancel") {
                        token = ""
                        isReplacing = false
                    }
                    .accessibilityIdentifier("settings-code-hosting-replace-cancel-\(name)")
                    if model.running == .replace(name) { ProgressView().controlSize(.small) }
                }
            }
        } else {
            Button("Replace token\u{2026}") { isReplacing = true }
                .disabled(model.isRunning)
                .accessibilityIdentifier("settings-code-hosting-replace-\(name)")
        }
    }

    /// Hands the token to `yh` and empties the field before the run starts: the app keeps no copy.
    private func replaceByPaste() {
        let value = token
        token = ""
        Task {
            if await model.replaceToken(of: name, with: value) { isReplacing = false }
        }
    }

    private func replaceByImport() {
        token = ""
        Task {
            if await model.replaceTokenFromGitHubCLI(of: name) { isReplacing = false }
        }
    }
}
