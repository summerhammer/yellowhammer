import Config
import Domain
import SwiftUI

/// The Project configuration files the loader refused, each with its path and every decode or
/// validation error. A refused Project is never a Project row anywhere (OQ79), so this pane is where
/// the Operator finds out why a file they wrote does not show up. Fixing the file is the Operator's edit.
/// The one action is removal, offered only on a card whose Project `yh project remove` would act on (it
/// forgives some refusals); `yh` does the removal and the app only runs it.
struct RefusedFilesPane: View {
    /// Nil until the configuration has been read.
    let configured: ConfiguredProjects?
    /// Called after `yh` removed a refused Project, once the removal sheet has closed.
    let onRemoved: () -> Void

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
                RefusedFileCard(
                    offset: offset, file: file, entry: configured?.removableEntry(for: file), onRemoved: onRemoved
                )
                // A different file is a different card, so it never shares a removal model.
                .id(file.file)
            }
        }
    }
}

/// One refused file: its path, its errors, and either *Remove Project…* or why `yh` cannot remove it.
private struct RefusedFileCard: View {
    let offset: Int
    let file: InvalidProject
    /// The Project `yh` would remove for this file; nil when it would refuse.
    let entry: ConfiguredProjects.Entry?
    let onRemoved: () -> Void

    var body: some View {
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
            if let entry {
                RefusedFileRemoval(entry: entry, onRemoved: onRemoved)
            } else {
                Text(
                    "yh can\u{2019}t remove this Project " // glossary:ignore GL001
                        + "until its file loads; fix the errors above."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-refused-unremovable-\(offset)")
            }
        }
    }
}

/// *Remove Project…* for a refused file, with the removal sheet. Owns the removal model, so it is created
/// once per card.
private struct RefusedFileRemoval: View {
    let entry: ConfiguredProjects.Entry
    let onRemoved: () -> Void

    @State private var removal: ProjectRemovalModel
    @State private var isRemoving = false

    init(entry: ConfiguredProjects.Entry, onRemoved: @escaping () -> Void) {
        self.entry = entry
        self.onRemoved = onRemoved
        _removal = State(initialValue: ProjectRemovalModel(projectID: entry.id))
    }

    var body: some View {
        HStack(spacing: 12) {
            Button("Remove Project\u{2026}", systemImage: "trash", role: .destructive) { // glossary:ignore GL001
                isRemoving = true
            }
                .disabled(!removal.isAvailable)
                .help("Remove this Project from this Mac; its Journal is kept") // glossary:ignore GL001
                .accessibilityIdentifier("settings-refused-remove-\(entry.id.rawValue)") // glossary:ignore GL001
            if !removal.isAvailable {
                Text("Not available while the app reads another configuration directory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "settings-refused-remove-unavailable-\(entry.id.rawValue)" // glossary:ignore GL001
                    )
            }
            Spacer(minLength: 0)
        }
        // Removal reads the configuration again only once the sheet has closed, as in `ProjectSettingsPane`.
        .sheet(
            isPresented: $isRemoving,
            onDismiss: {
                if removal.phase == .removed {
                    onRemoved()
                } else {
                    removal.reset()
                }
            },
            content: { ProjectRemovalSheet(model: removal, name: entry.name, isPresented: $isRemoving) }
        )
    }
}
