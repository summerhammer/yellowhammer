import Config
import Domain
import SwiftUI

extension SetupWizardModel {
    /// Whether Add Project was confirmed: from then on the hub shows the run, and its steps are read-only.
    var hasStartedRun: Bool { isRunning || runExitStatus != nil }

    /// Whether a missing machine-wide prerequisite locks the steps. A started run never is: it shows the run.
    var isAwaitingPrerequisites: Bool { readiness.blocksAddProject && !hasStartedRun }
}

/// The hub: the step list on the left, and on the right the open step, or the run once it started. While a
/// prerequisite is missing, the list starts with it, the steps are locked, and the right pane shows it.
struct SetupWizardHub: View {
    @Bindable var model: SetupWizardModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HubSidebarHeader(ready: model.draft.readyCount, total: AddProjectDraft.Step.allCases.count)
                sidebar
            }
            .frame(width: 240)
            .background(.surface)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                if model.hasStartedRun {
                    WizardRunView(model: model)
                } else if model.isAwaitingPrerequisites {
                    SetupReadinessPanel(readiness: model.readiness)
                } else {
                    StepHeading(step: model.draft.step).padding([.horizontal, .top], 20)
                    if model.draft.step == .linearProject, !model.teamsFailure.isEmpty {
                        teamsFailure
                    }
                    WizardStepBody(
                        step: model.draft.step, draft: $model.draft, linearWorkspaces: model.linearWorkspaces,
                        onSelectInstallation: { name in Task { await model.selectLinearInstallation(name) } }
                    )
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var sidebar: some View {
        List(selection: selection) {
            if model.isAwaitingPrerequisites {
                Section("Prerequisites") {
                    ForEach(model.readiness.missing, id: \.self) { prerequisite in
                        Label(prerequisite.title, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.primary, .warning)
                            .padding(.vertical, 3)
                            .accessibilityIdentifier("setup-prerequisite-\(prerequisite.identifier)")
                    }
                }
            }
            Section {
                ForEach(AddProjectDraft.Step.allCases) { step in
                    WizardSidebarRow(
                        title: step.shortTitle,
                        summary: model.draft.summary(of: step),
                        status: model.draft.status(of: step),
                        problemCount: model.draft.problems(in: step).count
                    )
                    .tag(step)
                    .accessibilityIdentifier("setup-step-\(step)")
                }
                .disabled(model.isAwaitingPrerequisites)
            } header: {
                if model.isAwaitingPrerequisites { Text("Steps") }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .disabled(model.hasStartedRun)
    }

    private var selection: Binding<AddProjectDraft.Step?> {
        Binding {
            model.draft.step
        } set: { step in
            guard let step else { return }
            model.draft.go(to: step)
        }
    }

    /// What `yh --print-choices` printed when it could not list the teams. An existing Linear project's id
    /// still works without them.
    private var teamsFailure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The teams could not be read from Linear.")
                .foregroundStyle(.secondary)
            Text(model.teamsFailure.joined(separator: "\n"))
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding([.horizontal, .top], 20)
        .accessibilityIdentifier("setup-teams-failure")
    }
}

/// The sidebar's heading: what the sheet is and how many steps are ready.
private struct HubSidebarHeader: View {
    let ready: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Add Project").font(.title3.weight(.semibold))
            Text("\(ready) of \(total) ready")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding([.horizontal, .top], 16)
        .padding(.bottom, 8)
    }
}

/// One hub row: a title, its summary, and a trailing tick when done or a problem count once visited.
struct WizardSidebarRow: View {
    let title: String
    let summary: String
    let status: AddProjectDraft.StepStatus
    let problemCount: Int

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            switch status {
            case .done:
                Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(.success)
                    .accessibilityLabel("Done")
            case .problem:
                Text("\(problemCount)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.onError)
                    .padding(.horizontal, 6)
                    .background(.error, in: .capsule)
                    .accessibilityLabel("\(problemCount) problems")
            case .current, .upcoming:
                EmptyView()
            }
        }
        .padding(.vertical, 3)
    }
}

/// A step's heading: its title and the sentence that says what it decides.
struct StepHeading: View {
    let step: AddProjectDraft.Step

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(step.title).font(.title2.weight(.semibold))
            Text(step.explanation)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The hub's footer: Cancel; what is still needed; Add Project — or, after the run, only Done or Close.
struct SetupWizardFooter: View {
    let model: SetupWizardModel
    let onAdded: @MainActor (ProjectID) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 12) {
            if let status = model.runExitStatus {
                Spacer()
                if status == 0 {
                    Button("Done") {
                        if let id = model.declaredProjectID { onAdded(id) }
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("setup-done")
                } else {
                    // No way back to the steps: the Project file may already be written.
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("setup-close")
                }
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isRunning)
                    .accessibilityIdentifier("setup-cancel")
                Spacer()
                if model.isRunning {
                    Button("Adding…") {}
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                } else {
                    if !model.isAwaitingPrerequisites { readiness }
                    Button("Add Project") { model.requestAdd() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canAddProject)
                        .accessibilityIdentifier("setup-add-project")
                }
            }
        }
        .padding(16)
    }

    /// Progress as words: which steps are still needed, or that nothing is.
    @ViewBuilder private var readiness: some View {
        if let stillNeeded = model.draft.stillNeeded {
            Text(stillNeeded)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("setup-still-needed")
        } else {
            Label("Ready to add", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.success)
                .accessibilityIdentifier("setup-still-needed")
        }
    }
}

extension View {
    /// Asks before adding, because adding is the moment the id becomes permanent.
    func addProjectConfirmation(
        isPresented: Binding<Bool>, displayName: String, projectID: String, onConfirm: @escaping () -> Void
    ) -> some View {
        alert(
            "Add \u{201c}\(displayName)\u{201d} with the id \u{201c}\(projectID)\u{201d}?",
            isPresented: isPresented
        ) {
            Button("Add Project", action: onConfirm)
                .accessibilityIdentifier("setup-confirm-add")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The id names the Project file, its Journal and its three LaunchAgents. "
                + "It can\u{2019}t be changed after the Project is added.")
        }
    }
}
