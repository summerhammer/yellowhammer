import SwiftUI

/// The Linear step of `SetupWizardView` (roadmap P17.6/P17.9): split into its own file so
/// `SetupWizardView.swift` stays under its own line budget. Not `private`, since `SetupWizardView.body`
/// (the other file) constructs it. The install UI itself is `LinearInstallationView`, shared with Settings.
struct SetupLinearStepView: View {
    @Bindable var model: SetupWizardModel

    var body: some View {
        Form {
            Section("Linear") { // glossary:ignore GL001
                Text(
                    "Yellowhammer connects to Linear through its own app, approved once by a " // glossary:ignore GL001
                        + "workspace admin — on this Mac, or remotely through a link you send them."
                )
                .foregroundStyle(.secondary)
                LinearInstallationView(model: model.linearInstallation, offersReinstall: false)
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
    }
}
