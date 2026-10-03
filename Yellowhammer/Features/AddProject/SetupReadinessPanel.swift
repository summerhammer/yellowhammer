import Config
import SwiftUI

/// One row per missing prerequisite, which opens the matching Settings section. The agent CLI route is
/// machine-wide, so the sheet never edits it. (The Linear workspace and the Operator identity are chosen in
/// the wizard's Linear step.)
struct SetupReadinessPanel: View {
    let readiness: SetupReadiness
    /// Reads the machine again, so a fix made in Settings is seen without closing the sheet.
    let onCheckAgain: () -> Void

    @Environment(SettingsRequest.self) private var settingsRequest
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                Text("Adding a Project needs this first. It is set once for this Mac.")
                Button("Check Again", action: onCheckAgain)
                    .accessibilityIdentifier("setup-readiness-check-again")
            }
            ForEach(readiness.missing, id: \.self) { prerequisite in
                Section {
                    switch prerequisite {
                    case .agentCLIRoute:
                        Text("Declare an agent CLI and give it a route in the base Routing Table.")
                            .foregroundStyle(.secondary)
                        Button("Open Settings \u{2192} Agent CLIs\u{2026}") {
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
        case .agentCLIRoute: "agentCLIRoute"
        }
    }
}

#Preview {
    SetupReadinessPanel(readiness: SetupReadiness(machine: nil), onCheckAgain: {})
        .environment(SettingsRequest())
        .frame(width: 620, height: 480)
}
