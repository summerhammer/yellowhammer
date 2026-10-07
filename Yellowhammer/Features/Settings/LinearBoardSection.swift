import SwiftUI

/// Linear's section of the Boards pane: one card per connected Board Connection, then the way to connect
/// another workspace, like the Add Project sheet's Repo cards and "Add Repo…". Everything Linear-specific in
/// Boards is here or in the views it draws, so another board vendor's section is a sibling of this one.
struct LinearBoardSection: View {
    let model: LinearWorkspacesModel
    var highlightedBoardConnection: String?
    @State private var isConnecting = false

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 12) {
                Text("Linear").font(.headline)
                Text(
                    "Yellowhammer connects to Linear through its own app, approved once by a workspace admin "
                        + "\u{2014} on this Mac, or remotely through a link you send them."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if let loadFailure = model.loadFailure {
                    SettingsFailureText(text: loadFailure, identifier: "settings-linear-load-failure")
                }
                ForEach(model.workspaces) { workspace in
                    LinearWorkspaceCard(
                        model: model, workspace: workspace,
                        isHighlighted: highlightedBoardConnection == workspace.name
                    )
                    .id(workspace.name)
                }
                if !model.removalMessage.isEmpty {
                    WizardNote(text: model.removalMessage.joined(separator: "\n"))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("settings-linear-removed")
                }
                connect
            }
            .onAppear {
                if let target = highlightedBoardConnection {
                    Task { @MainActor in
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
            .onChange(of: highlightedBoardConnection) { _, target in
                if let target {
                    withAnimation {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-linear-section")
    }

    /// With no workspace connected, the install is the section's content. Otherwise it sits behind the
    /// button until it is asked for; once an install is running or has finished, its own phases show.
    @ViewBuilder private var connect: some View {
        if model.workspaces.isEmpty {
            if model.loadFailure == nil {
                Text("No Linear workspace is connected yet.")
                    .foregroundStyle(.secondary)
            }
            installation(offersCancel: false)
        } else if isConnecting || model.connectAnother.phase != .notInstalled {
            installation(offersCancel: true)
        } else {
            Button("Connect a Linear Workspace\u{2026}", systemImage: "plus") { isConnecting = true }
                .accessibilityIdentifier("settings-linear-connect")
        }
    }

    /// `offersCancel` closes the install again before one starts; once one runs, its own Cancel stops it.
    private func installation(offersCancel: Bool) -> some View {
        WizardBlock(title: "Connect a Linear workspace") {
            VStack(alignment: .leading, spacing: 10) {
                LinearInstallationView(
                    model: model.connectAnother,
                    offersReinstall: true,
                    arrangesInstallButtonsInRow: true,
                    onDismiss: offersCancel ? { isConnecting = false } : nil
                )
            }
            .padding(12)
        }
    }
}
