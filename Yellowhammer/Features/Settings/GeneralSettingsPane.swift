import Config
import SwiftUI

/// The machine-wide settings of the Settings window's General section: the GitHub credential, Orca ADE and the
/// Command Line Tool. The Board connections (Boards), Agent CLIs and the base Routing Table have panes of their
/// own (P18.15, P18.16).
struct GeneralSettingsPane: View {
    @Environment(CommandLineToolModel.self) private var commandLineToolModel
    @State private var gitHub = GitHubCredentialModel()

    var body: some View {
        SettingsPane(
            title: "General",
            explanation: "What this Mac shares with every Project: the GitHub credential, " // glossary:ignore GL001
                + "Orca ADE and the Command Line Tool."
        ) {
            GitHubCredentialView(model: gitHub, mode: .settings)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("settings-github")
            orcaADE
            commandLineToolCard
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-general-pane")
        .onAppear {
            commandLineToolModel.refresh()
        }
        .task { await gitHub.check(repoPaths: []) }
        .onDisappear { gitHub.terminate() }
    }

    private var orcaADE: some View {
        WizardBlock(
            title: "Orca ADE", // glossary:ignore GL001
            footer: "Yellowhammer has no Orca ADE setting of its own." // glossary:ignore GL001
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Orca ADE creates, places and cleans up every Worktree; Yellowhammer only records their paths.")
                Text(
                    "Setup resolves the orca executable on the PATH it writes into each Project\u{2019}s scheduled "
                        + "jobs, and warns when orca is not on it."
                )
                .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-orca-ade")
    }

    private var commandLineToolCard: some View {
        WizardBlock(
            title: "Command Line Tool",
            footer: "Operator-initiated symlink for human interactive terminal access. Scheduled jobs are unaffected."
        ) {
            commandLineToolContent
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-command-line-tool")
    }

    @ViewBuilder
    private var commandLineToolContent: some View {
        switch commandLineToolModel.state {
        case .installed:
            WizardBlockRow(
                label: "Installed at \(commandLineToolModel.linkPath)",
                detail: "Points to \(commandLineToolModel.runningExecutablePath)",
                labelIdentifier: "command-line-tool-status"
            ) {
                Button("Uninstall…") {
                    commandLineToolModel.promptUninstall()
                }
                .accessibilityIdentifier("command-line-tool-uninstall")
            }

        case .notInstalled:
            WizardBlockRow(
                label: "Not installed",
                detail: "Creates a symlink at \(commandLineToolModel.linkPath) pointing to "
                    + "\(commandLineToolModel.runningExecutablePath).",
                labelIdentifier: "command-line-tool-status"
            ) {
                Button("Install…") {
                    commandLineToolModel.promptInstall()
                }
                .accessibilityIdentifier("command-line-tool-install")
            }

        case .dangling(target: let target):
            WizardBlockRow(
                label: "Points to a missing or different copy",
                detail: "Points to \(target); current app is at \(commandLineToolModel.runningExecutablePath).",
                labelIdentifier: "command-line-tool-status"
            ) {
                HStack(spacing: 8) {
                    Button("Update…") {
                        commandLineToolModel.promptUpdate()
                    }
                    .accessibilityIdentifier("command-line-tool-update")
                    if target.hasSuffix("/Contents/MacOS/yh") {
                        Button("Uninstall…") {
                            commandLineToolModel.promptUninstall()
                        }
                        .accessibilityIdentifier("command-line-tool-uninstall")
                    }
                }
            }

        case .mismatched(target: let target):
            if !commandLineToolModel.isSymlink {
                WizardBlockRow(
                    label: "A file already exists at \(commandLineToolModel.linkPath) and is not a symlink",
                    detail: "To use the Command Line Tool at this path, remove or rename the existing file manually.",
                    labelIdentifier: "command-line-tool-status"
                ) {
                    Button("Install…") {}
                        .disabled(true)
                        .accessibilityIdentifier("command-line-tool-install")
                }
            } else {
                WizardBlockRow(
                    label: "Points to a missing or different copy",
                    detail: "Points to \(target); current app is at \(commandLineToolModel.runningExecutablePath).",
                    labelIdentifier: "command-line-tool-status"
                ) {
                    HStack(spacing: 8) {
                        Button("Update…") {
                            commandLineToolModel.promptUpdate()
                        }
                        .accessibilityIdentifier("command-line-tool-update")
                        if target.hasSuffix("/Contents/MacOS/yh") {
                            Button("Uninstall…") {
                                commandLineToolModel.promptUninstall()
                            }
                            .accessibilityIdentifier("command-line-tool-uninstall")
                        }
                    }
                }
            }
        }
    }
}
