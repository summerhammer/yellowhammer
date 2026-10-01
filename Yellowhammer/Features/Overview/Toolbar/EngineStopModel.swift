import Domain
import Foundation
import Observation

/// Runs `yh stop --project <id>` through ``SetupEngine``, the app's seam for the bundled `yh`, and keeps
/// what the window needs: which Projects a stop is running for, and yh's own words when one failed. The app records
/// nothing itself; it never invents a result.
@MainActor
@Observable
final class EngineStopModel {
    /// The Projects a `yh stop` is running for. Per Project, so selecting another one mid-stop neither
    /// shows this stop's progress there nor withholds Stop from it.
    private(set) var stopping: Set<ProjectID> = []
    /// yh's last lines, set when `yh stop` could not be run or exited non-zero.
    var failure: String?
    private let engine = SetupEngine()

    func stop(project: ProjectID) async {
        guard stopping.insert(project).inserted else { return }
        defer { stopping.remove(project) }
        if let failed = await EngineGestureRun.failure(
            engine: engine, command: "stop", arguments: ["stop", "--project", project.rawValue]
        ) {
            failure = failed
        }
    }

    func isStopping(_ project: ProjectID?) -> Bool {
        project.map(stopping.contains) ?? false
    }
}
