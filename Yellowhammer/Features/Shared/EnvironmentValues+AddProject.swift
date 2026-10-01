import Domain
import SwiftUI

/// Asks the window to present the Add Project sheet. A view calls this instead of presenting the wizard
/// itself, so no feature reaches into `AddProject`.
@MainActor
struct AddProjectAction {
    private let present: (_ onAdded: @escaping @MainActor (ProjectID) -> Void) -> Void

    init(_ present: @escaping (_ onAdded: @escaping @MainActor (ProjectID) -> Void) -> Void) {
        self.present = present
    }

    /// Presents the sheet; `onAdded` runs with the new Project's id once the Operator finishes it.
    /// Cancelling never calls it.
    func callAsFunction(onAdded: @escaping @MainActor (ProjectID) -> Void = { _ in }) {
        present(onAdded)
    }
}

extension EnvironmentValues {
    /// Opens the Add Project sheet in the current window. A no-op where no window installs it.
    @Entry var addProject = AddProjectAction { _ in }
}
