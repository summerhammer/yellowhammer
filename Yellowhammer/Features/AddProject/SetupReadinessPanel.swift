import Config
import SwiftUI

/// The hub's right pane while a machine-wide prerequisite is missing: one section per missing prerequisite,
/// each opening the matching Settings section. The agent CLI route is machine-wide, so the sheet never edits
/// it; the sheet reads the machine again when its window becomes key, so the fix is seen on return. (The
/// Linear workspace and the Operator identity are chosen in the wizard's Linear step.)
struct SetupReadinessPanel: View {
    let readiness: SetupReadiness

    @Environment(SettingsRequest.self) private var settingsRequest
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Before You Start").font(.title2.weight(.semibold))
                Text("Set these up once for this Mac in Settings. The steps unlock when you come back.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)
            Form {
                ForEach(readiness.missing, id: \.self) { prerequisite in
                    Section {
                        switch prerequisite {
                        case .agentCLIRoute:
                            Text("Declare an agent CLI and give it a route in the base Routing Table.")
                                .foregroundStyle(.secondary)
                            ForEach(readiness.executableProblems, id: \.self) { problem in
                                SettingsFailureText(text: problem)
                            }
                            Button("Open Settings \u{2192} Agent CLIs\u{2026}") {
                                settingsRequest.request(nil, section: .agentCLIs)
                                openWindow(id: SettingsWindow.windowID)
                            }
                            .accessibilityIdentifier("setup-open-settings-agentCLIRoute")
                        }
                    } header: {
                        // On the header alone: an identifier on the Section replaces every row's own.
                        Text(prerequisite.title)
                            .accessibilityIdentifier("setup-readiness-\(prerequisite.identifier)")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .accessibilityIdentifier("setup-readiness")
    }
}

extension SetupReadiness.Prerequisite {
    /// The suffix of this prerequisite's accessibility identifiers.
    var identifier: String {
        switch self {
        case .agentCLIRoute: "agentCLIRoute"
        }
    }
}

#Preview {
    SetupReadinessPanel(readiness: SetupReadiness(machine: nil))
        .environment(SettingsRequest())
        .frame(width: 620, height: 480)
}
