import Domain
import Observation

/// The hand-off from a gesture that opens Settings (Cmd+, or the Pulse's "Open Settings") to the
/// Settings window: the Project the key main window shows, which Settings preselects, and optionally
/// a section to open instead.
///
/// It holds one gesture's request and nothing else, so it is not a cache of any Project's state. The
/// token changes on every request, so asking again for the same Project, with Settings already open, is
/// still a request. The two windows' selections stay independent after the hand-off.
@MainActor @Observable
final class SettingsRequest {
    /// The Project to preselect; nil when no main window is key, which leaves Settings where it was.
    private(set) var project: ProjectID?
    /// The section to open; nil to keep today's Project view.
    private(set) var section: SettingsSection?
    /// Changes with every request.
    private(set) var token = 0

    func request(_ project: ProjectID?, section: SettingsSection? = nil) {
        self.project = project
        self.section = section
        token += 1
    }
}
