import Domain
import Observation

/// The Project ids that `yellowhammer://project/<id>` links have named since the app launched, app-wide.
///
/// A main window whose value names an id that is neither configured nor refused states so only when a
/// link named that id (scope-windows-to-a-project, AC 5). Any other such value is dropped: one macOS
/// restored with the window after its Project was removed, or one left behind by a Project removed while
/// the window was open. App-wide, not per window, because a link to a Project another window does not
/// show opens a new window, which never sees the link itself.
///
/// Never saved: a saved record would bring back the very values it exists to tell apart.
@MainActor @Observable
final class DeepLinkedProjects {
    private var ids: Set<ProjectID> = []

    /// Called before the link scopes or opens a window.
    func record(_ id: ProjectID) {
        ids.insert(id)
    }

    func contains(_ id: ProjectID) -> Bool {
        ids.contains(id)
    }
}
