import Observation

/// Records that a Project was added, app-wide. Every window that lists Projects reads its configuration
/// again when the token changes, because a sheet finishing fires neither appear nor didBecomeActive.
///
/// It holds a counter and nothing else, so it is not a cache of any Project's state.
@MainActor @Observable
final class ProjectAdditions {
    /// Changes with every added Project.
    private(set) var token = 0

    func record() {
        token += 1
    }
}
