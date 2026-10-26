import Config
import Domain
import Pulse
import SwiftUI

/// Read-only sheet presenting an Attempt or Night's recorded dispatches.
struct PromptViewerSheet: View {
    @State private var model: PromptViewerModel
    @Environment(\.dismiss) private var dismiss

    init(
        projectID: ProjectID,
        issueID: String,
        attemptID: Int64,
        selectedItemID: String? = nil,
        configurationDirectory: URL = ConfigurationDirectory.current
    ) {
        _model = State(
            initialValue: PromptViewerModel(
                projectID: projectID,
                issueID: issueID,
                attemptID: attemptID,
                selectedItemID: selectedItemID,
                configurationDirectory: configurationDirectory
            )
        )
    }

    init(
        projectID: ProjectID? = nil,
        scope: DispatchPromptIndex.Scope,
        selectedItemID: String? = nil,
        configurationDirectory: URL = ConfigurationDirectory.current
    ) {
        _model = State(
            initialValue: PromptViewerModel(
                projectID: projectID,
                scope: scope,
                selectedItemID: selectedItemID,
                configurationDirectory: configurationDirectory
            )
        )
    }

    init(
        machineRun: DispatchPromptIndex.MachineRun,
        selectedItemID: String? = nil,
        configurationDirectory: URL = ConfigurationDirectory.current
    ) {
        _model = State(
            initialValue: PromptViewerModel(
                machineRun: machineRun,
                selectedItemID: selectedItemID,
                configurationDirectory: configurationDirectory
            )
        )
    }

    var body: some View {
        NavigationSplitView {
            PromptViewerListView(
                items: model.index?.items ?? [],
                emptyState: model.index?.emptyState,
                selectedItemID: $model.selectedItemID
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            detailPane
        }
        .frame(minWidth: 760, minHeight: 520)
        .toolbar {
            toolbarItems
        }
        .task {
            await model.load()
        }
        .confirmationDialog(
            "Copy Prompt to Clipboard",
            isPresented: $model.confirmingCopy,
            titleVisibility: .visible
        ) {
            Button("Copy Prompt") {
                model.copySelectedPrompt()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DispatchPromptItem.copyEvidenceNotice)
        }
        .confirmationDialog(
            "Delete Recorded Prompts",
            isPresented: $model.confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Recorded Prompts", role: .destructive) {
                Task {
                    await model.deleteSelected()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This deletes the retained instruction text and captured schema for the selected dispatch from disk. " +
                "Journal outcomes and execution history are not changed."
            )
        }
        .alert(
            "Recorded Prompts could not be deleted",
            isPresented: Binding(
                get: { model.deleteFailure != nil },
                set: { if !$0 { model.deleteFailure = nil } }
            )
        ) {
            Button("OK") { model.deleteFailure = nil }
        } message: {
            Text(model.deleteFailure ?? "")
        }
        .accessibilityIdentifier("prompts-viewer-sheet")
    }

    @ViewBuilder
    private var detailPane: some View {
        if let failure = model.readFailure {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(failure)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let selected = model.selectedItem {
            PromptViewerDetailView(item: selected)
        } else if model.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("Select a dispatch to inspect its prompt.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button("Copy Prompt\u{2026}") {
                model.confirmingCopy = true
            }
            .disabled(copyDisabled)
            .accessibilityIdentifier("prompts-copy-button")
        }

        ToolbarItem(placement: .automatic) {
            Button("Delete Recorded Prompts\u{2026}") {
                model.confirmingDelete = true
            }
            .disabled(deleteDisabled)
            .accessibilityIdentifier("prompts-delete-button")
        }

        ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var copyDisabled: Bool {
        guard let item = model.selectedItem else { return true }
        return (item.instruction == nil && item.outputSchema == nil)
    }

    private var deleteDisabled: Bool {
        guard let item = model.selectedItem else { return true }
        return item.recordID == nil || model.isDeleting
    }
}
