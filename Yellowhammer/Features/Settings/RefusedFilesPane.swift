import Config
import SwiftUI

/// The Project configuration files the loader refused, each with its path and every decode or
/// validation error. A refused Project is never a Project row anywhere (OQ79), so this pane is where
/// the Operator finds out why a file they wrote does not show up. The app only shows it: fixing the file
/// is the Operator's edit.
struct RefusedFilesPane: View {
    /// Nil until the configuration has been read.
    let configured: ConfiguredProjects?

    var body: some View {
        SettingsPane(
            title: "Refused Files",
            explanation: "Project configuration files Yellowhammer could not load, with every error the loader "
                + "found. A refused file is not a Project anywhere in the app until you fix it."
        ) {
            if let configured {
                if let failure = configured.loadFailure {
                    // The whole configuration is unreadable, so an empty list would claim nothing is refused.
                    WizardBlock(title: "Yellowhammer can\u{2019}t read its configuration.", boxed: false) {
                        SettingsFailureText(text: failure)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("settings-configuration-unreadable")
                } else if configured.refused.isEmpty {
                    Label("No Project configuration file is refused.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.success)
                        .accessibilityIdentifier("settings-refused-none")
                } else {
                    list(configured.refused)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func list(_ refused: [InvalidProject]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(refused.enumerated()), id: \.offset) { offset, file in
                SettingsCard(hasProblem: true) {
                    Text(file.file)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("settings-refused-file-\(offset)")
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(file.errors.enumerated()), id: \.offset) { index, error in
                            SettingsFailureText(
                                text: error.description, identifier: "settings-refused-file-\(offset)-error-\(index)"
                            )
                        }
                    }
                }
            }
        }
    }
}
