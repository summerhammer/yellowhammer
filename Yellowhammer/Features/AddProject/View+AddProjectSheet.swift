import Domain
import SwiftUI

extension View {
    /// Lets this window present the Add Project sheet: installs `\.addProject` for the views below and
    /// presents the Setup wizard as a sheet. A sheet is per window, so each window applies it once.
    func addProjectSheet() -> some View {
        modifier(AddProjectSheetModifier())
    }
}

private struct AddProjectSheetModifier: ViewModifier {
    @State private var isPresented = false
    /// Runs with the new Project's id after the Operator presses Done. Held only while the sheet is up.
    @State private var pendingOnAdded: (@MainActor (ProjectID) -> Void)?
    @Environment(ProjectListChanges.self) private var listChanges

    func body(content: Content) -> some View {
        content
            .environment(\.addProject, AddProjectAction { onAdded in
                pendingOnAdded = onAdded
                isPresented = true
            })
            .sheet(
                isPresented: $isPresented,
                onDismiss: { pendingOnAdded = nil },
                content: {
                    SetupWizardView(
                        onAdded: { id in pendingOnAdded?(id) },
                        onRunEnded: { listChanges.record() }
                    )
                }
            )
    }
}
