import Config
import SwiftUI

/// One row per missing prerequisite; Linear is fixed in place, the others open the matching Settings
/// section. The Operator identity and agent CLI routing are machine-wide, so the sheet never edits them.
struct SetupReadinessPanel: View {
    let readiness: SetupReadiness
    let linearInstallation: LinearInstallationModel
    /// Reads the machine again, so a fix made in Settings is seen without closing the sheet.
    let onCheckAgain: () -> Void

    @Environment(SettingsRequest.self) private var settingsRequest
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                Text(
                    "Adding a Project needs these first. They are set once for this Mac."
                )
                Button("Check Again", action: onCheckAgain)
                    .accessibilityIdentifier("setup-readiness-check-again")
            }
            ForEach(readiness.missing, id: \.self) { prerequisite in
                Section {
                    switch prerequisite {
                    case .linearInstallation:
                        Text(
                            "Yellowhammer connects to Linear through its own app, approved once "
                                + "by a workspace admin."
                        )
                        .foregroundStyle(.secondary)
                        LinearInstallationView(model: linearInstallation, offersReinstall: false)
                    case .operatorIdentity:
                        Text(
                            "Who you are in Linear, so Yellowhammer knows which questions are yours."
                        )
                        .foregroundStyle(.secondary)
                        Button("Open Settings \u{2192} General…") {
                            settingsRequest.request(nil, section: .general)
                            openWindow(id: SettingsWindow.windowID)
                        }
                        .accessibilityIdentifier("setup-open-settings-operatorIdentity")
                    case .agentCLIRoute:
                        Text("Declare an agent CLI and give it a route in the base Routing Table.")
                            .foregroundStyle(.secondary)
                        Button("Open Settings \u{2192} Agent CLIs…") {
                            settingsRequest.request(nil, section: .agentCLIs)
                            openWindow(id: SettingsWindow.windowID)
                        }
                        .accessibilityIdentifier("setup-open-settings-agentCLIRoute")
                    }
                } header: {
                    // On the header alone: an identifier on the Section replaces every row's own.
                    Text(prerequisite.title)
                        .accessibilityIdentifier("setup-readiness-\(prerequisiteID(prerequisite))")
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("setup-readiness")
    }

    private func prerequisiteID(_ prerequisite: SetupReadiness.Prerequisite) -> String {
        switch prerequisite {
        case .linearInstallation: "linearInstallation"
        case .operatorIdentity: "operatorIdentity"
        case .agentCLIRoute: "agentCLIRoute"
        }
    }
}

#Preview {
    SetupReadinessPanel(
        readiness: SetupReadiness(linearInstalled: false, machine: nil),
        linearInstallation: LinearInstallationModel(phase: .notInstalled),
        onCheckAgain: {}
    )
    .environment(SettingsRequest())
    .frame(width: 620, height: 480)
}
