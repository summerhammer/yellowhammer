import Config
import Domain
import SwiftUI

/// The Add Project sheet: everything `yh setup` does, as a hub of six steps any of which can be opened at
/// any time, driven by ``SetupWizardModel``. It exists only to add a Project, reached from an Add Project
/// action in a window, and it shows no status or cross-Project summary. The one machine-wide prerequisite
/// is an agent CLI route, which is not set here: while it is missing the readiness panel replaces the hub
/// and points at where to set it. The Linear workspace and its Operator identity are chosen in the Linear
/// step; a Linear workspace connected there stays in the registry if the sheet is cancelled. Cancelling
/// before the run writes no Project: only `yh setup --init` writes a Project file, and Cancel is disabled
/// while it runs.
struct SetupWizardView: View {
    /// Reports the added Project when the Operator presses Done, before the sheet closes.
    let onAdded: @MainActor (ProjectID) -> Void
    /// Called once each time a run finishes, whatever its exit status: a failed run may already have
    /// written the Project file, so the windows that list Projects must read again.
    let onRunEnded: @MainActor () -> Void
    @State private var model = SetupWizardModel()

    var body: some View {
        VStack(spacing: 0) {
            main
            Divider()
            SetupWizardFooter(model: model, showsReadiness: showsHub, onAdded: onAdded)
        }
        .frame(minWidth: 860, minHeight: 600)
        .addProjectConfirmation(
            isPresented: $model.isConfirmingAdd,
            displayName: model.draft.displayName,
            projectID: model.draft.projectID
        ) {
            Task { await model.confirmAndRun() }
        }
        .interactiveDismissDisabled(model.isRunning)
        .task { await model.appeared() }
        .onChange(of: model.runExitStatus) { _, status in
            if status != nil { onRunEnded() }
        }
        // A fix made in the Settings window is seen on return; nothing polls and nothing stays resident.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.loadContext()
        }
        .onDisappear { model.terminateRun() }
    }

    /// Whether the hub, not the readiness panel, is showing. A started run always shows the hub,
    /// which is where its log is.
    private var showsHub: Bool {
        model.hasStartedRun || !model.readiness.blocksAddProject
    }

    @ViewBuilder private var main: some View {
        if showsHub {
            SetupWizardHub(model: model)
        } else {
            SetupReadinessPanel(readiness: model.readiness, onCheckAgain: { model.loadContext() })
        }
    }
}
