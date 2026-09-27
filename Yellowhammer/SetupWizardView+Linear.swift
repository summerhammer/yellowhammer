import AppKit
import Domain
import SwiftUI

/// The Linear step of `SetupWizardView` (roadmap P17.6/P17.9): split into its own file so
/// `SetupWizardView.swift` stays under its own line budget. Not `private`, since `SetupWizardView.body`
/// (the other file) constructs it.
struct SetupLinearStepView: View {
    @Bindable var model: SetupWizardModel
    @State private var didCopyApprovalLink = false

    var body: some View {
        Form {
            Section("Linear") { // glossary:ignore GL001
                Text(
                    "Yellowhammer connects to Linear through its own app, approved once by a " // glossary:ignore GL001
                        + "workspace admin — on this Mac, or remotely through a link you send them."
                )
                .foregroundStyle(.secondary)
                linearInstallContent
            }
            if !model.configExists {
                DisclosureGroup("Advanced", isExpanded: $model.showAdvanced) {
                    TextField("GitHub credential reference", text: $model.githubCredential)
                }
            }
            if !model.choicesErrorOutput.isEmpty {
                Section("yh output") {
                    Text(model.choicesErrorOutput.joined(separator: "\n"))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .task { await model.checkExistingLinearInstallation() }
    }

    @ViewBuilder private var linearInstallContent: some View {
        switch model.linearInstallPhase {
        case .checking:
            ProgressView("Checking for an existing installation…")
                .accessibilityIdentifier("setup-linear-checking")
        case .notInstalled:
            Button("Install here as a workspace admin…") { model.startLinearInstall() } // glossary:ignore GL001
                .accessibilityIdentifier("setup-linear-install")
            Button("Request approval from an admin…") { // glossary:ignore GL001
                model.startLinearInstall(remote: true)
            }
            .accessibilityIdentifier("setup-linear-request-remote")
        case .installing(let adminStatement):
            if !adminStatement.isEmpty {
                Text(adminStatement).font(.callout)
            }
            ProgressView()
        case .awaitingApproval(let adminStatement):
            if !adminStatement.isEmpty {
                Text(adminStatement).font(.callout)
            }
            Text("Waiting for a workspace admin to approve in the browser…") // glossary:ignore GL001
                .accessibilityIdentifier("setup-linear-awaiting")
            Button("Cancel") { model.cancelLinearInstall() }
        case .awaitingRemoteApproval(let adminStatement, let instruction, let link):
            awaitingRemoteApprovalContent(adminStatement: adminStatement, instruction: instruction, link: link)
        case .portsBusy(let text, let ports):
            Text(text).accessibilityIdentifier("setup-linear-ports-busy")
            ForEach(ports, id: \.port) { port in
                Text("Port \(port.port)\(port.command.map { " — \($0)" } ?? "")")
                    .font(.system(.footnote, design: .monospaced))
            }
            HStack {
                Button("Retry") { model.startLinearInstall() } // glossary:ignore GL001
                    .accessibilityIdentifier("setup-linear-retry")
                Button("Cancel") { model.cancelLinearInstall() }
            }
        case .failed(let text, let reason, let wasRemote):
            Text(text).accessibilityIdentifier("setup-linear-failed")
            failedButtons(reason: reason, wasRemote: wasRemote)
        case .installed(let workspaceName):
            Text(workspaceName.map { "Installed in the Linear workspace \($0)." } ?? "Installed.")
                .accessibilityIdentifier("setup-linear-installed")
        }
    }

    @ViewBuilder private func awaitingRemoteApprovalContent(
        adminStatement: String, instruction: String, link: String
    ) -> some View {
        if !adminStatement.isEmpty {
            Text(adminStatement).font(.callout)
        }
        Text(instruction)
        Text(link)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .accessibilityIdentifier("setup-linear-approval-link")
        Button(didCopyApprovalLink ? "Copied" : "Copy Link") { copyApprovalLink(link) } // glossary:ignore GL001
            .accessibilityIdentifier("setup-linear-copy-link")
        ProgressView("Waiting for the admin to approve…") // glossary:ignore GL001
            .accessibilityIdentifier("setup-linear-awaiting-remote")
        Button("Cancel") { model.cancelLinearInstall() }
    }

    private func copyApprovalLink(_ link: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(link, forType: .string)
        didCopyApprovalLink = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopyApprovalLink = false
        }
    }

    /// The reason (`nil` for a cancel or an unexpected exit) decides which retry buttons a failed
    /// attempt offers (roadmap P17.9): the relay's own reasons steer toward the path most likely to
    /// work next; anything else offers both, defaulting the primary retry to the mode that just failed.
    @ViewBuilder private func failedButtons(
        reason: LinearInstallEvent.FailureReason?, wasRemote: Bool
    ) -> some View {
        switch reason {
        case .relayUnreachable:
            HStack {
                Button("Retry") { model.startLinearInstall(remote: true) } // glossary:ignore GL001
                    .accessibilityIdentifier("setup-linear-retry")
                Button("Sign in on this Mac") { model.startLinearInstall() } // glossary:ignore GL001
                    .accessibilityIdentifier("setup-linear-install")
            }
        case .relayRateLimited:
            Button("Retry") { model.startLinearInstall(remote: true) } // glossary:ignore GL001
                .accessibilityIdentifier("setup-linear-retry")
        case .expired, .rejected:
            newLinkOrLocalButtons
        case .notCompleted where wasRemote:
            newLinkOrLocalButtons
        default:
            HStack {
                Button("Install again") { model.startLinearInstall(remote: wasRemote) } // glossary:ignore GL001
                    .accessibilityIdentifier("setup-linear-install")
                Button("Request approval from an admin…") { // glossary:ignore GL001
                    model.startLinearInstall(remote: true)
                }
                .accessibilityIdentifier("setup-linear-request-remote")
            }
        }
    }

    private var newLinkOrLocalButtons: some View {
        HStack {
            Button("New link") { model.startLinearInstall(remote: true) } // glossary:ignore GL001
                .accessibilityIdentifier("setup-linear-request-remote")
            Button("Install here instead") { model.startLinearInstall() } // glossary:ignore GL001
                .accessibilityIdentifier("setup-linear-install")
        }
    }
}
