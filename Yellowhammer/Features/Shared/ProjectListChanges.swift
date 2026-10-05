import Observation

/// Records that the list of Projects changed, app-wide: a Project was added or removed. Every window that
/// lists Projects reads its configuration again when the token changes, because a sheet finishing fires
/// neither appear nor didBecomeActive.
///
/// It holds a counter and nothing else, so it is not a cache of any Project's state.
@MainActor @Observable
final class ProjectListChanges {
    /// Changes with every added or removed Project.
    private(set) var token = 0

    func record() {
        token += 1
    }
}
