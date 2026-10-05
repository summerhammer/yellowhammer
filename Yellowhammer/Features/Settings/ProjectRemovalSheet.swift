import Domain
import SwiftUI

/// The sheet behind a Project pane's *Remove Project…*: what removal does and keeps, a field that must
/// hold the Project's id, then `yh`'s lines as it runs. A sheet and not a confirmation dialog, because
/// removal runs long and can fail partway, and the Operator reads `yh`'s own words either way.
///
/// The app does no removal work (ADR-001): the button runs `yh project remove`. On success the sheet closes
/// itself, and its owner reads the configuration again from `onDismiss`, so Settings never navigates away
/// while the sheet is still presented. While `yh` runs the sheet cannot be dismissed: removal is not
/// interrupted from the UI.
struct ProjectRemovalSheet: View {
    let model: ProjectRemovalModel
    /// The Project's configured name, in the title.
    let name: String
    @Binding var isPresented: Bool
    @State private var typedID = ""

    private var matches: Bool {
        typedID.trimmingCharacters(in: .whitespacesAndNewlines) == model.projectID.rawValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remove \u{201C}\(name)\u{201D}?")
                .font(.title2.weight(.semibold))
            switch model.phase {
            case .idle:
                confirmation
            case .running, .removed:
                running
            case .failed:
                failed
            }
        }
        .padding(20)
        .frame(width: 500)
        .interactiveDismissDisabled(model.phase == .running)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-project-remove-sheet") // glossary:ignore GL001
        .onChange(of: model.phase) { _, phase in
            if phase == .removed { isPresented = false }
        }
    }

    // MARK: Confirming

    @ViewBuilder private var confirmation: some View {
        WizardBlock(title: "Removing this Project", boxed: false) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Self.actions, id: \.self) { action in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\u{2022}")
                        Text(action).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.callout)
        }
        WizardNote(
            text: "Its Journal is kept, and so is everything on Linear: no issue is deleted. Removal is "
                + "refused while an Act of this Project is running."
        )
        VStack(alignment: .leading, spacing: 6) {
            Text("Type \(model.projectID.rawValue) to confirm")
                .font(.callout)
            TextField("", text: $typedID)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .accessibilityLabel("Type \(model.projectID.rawValue) to confirm")
                .accessibilityIdentifier("settings-project-remove-confirm-field") // glossary:ignore GL001
        }
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { isPresented = false }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("settings-project-remove-cancel") // glossary:ignore GL001
            // Red and never the default action: Return in the field must not remove a Project (HIG).
            Button("Remove Project", role: .destructive, action: startRemoval)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!matches)
                .accessibilityIdentifier("settings-project-remove-confirm") // glossary:ignore GL001
        }
    }

    /// What `yh` does, in plain words.
    private static let actions = [
        "Unloads its scheduled jobs (LaunchAgents) and deletes its Act logs.",
        "Comments on its in-flight Feature in Linear, if there is one.",
        "WIP-commits, pushes and removes each Worktree it holds.",
        "Closes its open Night.",
        "Deletes its configuration file."
    ]

    private func startRemoval() {
        guard matches, model.phase == .idle else { return }
        Task { await model.remove() }
    }

    // MARK: Running

    @ViewBuilder private var running: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Removing\u{2026}").foregroundStyle(.secondary)
        }
        ScrollView {
            Text(model.lines.joined(separator: "\n"))
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("settings-project-remove-output") // glossary:ignore GL001
        }
        .defaultScrollAnchor(.bottom)
        .frame(height: 160)
    }

    // MARK: Failing

    @ViewBuilder private var failed: some View {
        ScrollView {
            SettingsFailureText(
                text: model.failure ?? "", identifier: "settings-project-remove-failure", // glossary:ignore GL001
                monospaced: true
            )
        }
        .frame(maxHeight: 200)
        WizardNote(
            text: "Removal can be retried safely: nothing was recorded as complete, and the Project file "
                + "is kept."
        )
        HStack {
            Spacer()
            Button("Close") { isPresented = false }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("settings-project-remove-close") // glossary:ignore GL001
            Button("Try Again") { Task { await model.remove() } }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("settings-project-remove-retry") // glossary:ignore GL001
        }
    }
}
