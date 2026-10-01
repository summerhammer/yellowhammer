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
        if let configured {
            if let failure = configured.loadFailure {
                // The whole configuration is unreadable, so an empty list would claim nothing is refused.
                VStack(spacing: 8) {
                    Text("Yellowhammer can\u{2019}t read its configuration.")
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("settings-configuration-unreadable")
            } else if configured.refused.isEmpty {
                Text("No Project configuration file is refused.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("settings-refused-none")
            } else {
                list(configured.refused)
            }
        } else {
            ProgressView()
        }
    }

    private func list(_ refused: [InvalidProject]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Refused Project configuration files")
                    .font(.headline)
                ForEach(Array(refused.enumerated()), id: \.offset) { offset, file in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.file)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("settings-refused-file-\(offset)")
                        ForEach(Array(file.errors.enumerated()), id: \.offset) { index, error in
                            Text(error.description)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .accessibilityIdentifier("settings-refused-file-\(offset)-error-\(index)")
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
