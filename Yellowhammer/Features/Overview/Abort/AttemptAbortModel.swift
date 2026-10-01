import Domain
import Foundation
import Observation
import Pulse

/// One running Attempt of one Project: the unit an abort targets. `attemptID` is the Journal attempt id,
/// passed to `yh abort` verbatim.
struct AbortTarget: Hashable {
    let project: ProjectID
    let attemptID: String
}

/// Runs `yh abort --project <id> --attempt <n>` through ``SetupEngine``, the app's seam for the bundled
/// `yh`, and keeps what the window needs: which Attempts an abort is running for, and yh's own words when
/// one failed. The app records nothing itself: `yh abort` records the Operator's request in the engine, so
/// quitting the app cannot change the outcome. Nothing here polls.
@MainActor
@Observable
final class AttemptAbortModel {
    /// The Attempts a `yh abort` is running for, per Project and Attempt, so one abort in flight neither
    /// shows its progress on another Attempt nor withholds Abort Attempt from it.
    private(set) var aborting: Set<AbortTarget> = []
    /// yh's last lines, set when `yh abort` could not be run or exited non-zero.
    var failure: String?
    private let engine = SetupEngine()

    func abort(_ target: AbortTarget) async {
        guard aborting.insert(target).inserted else { return }
        defer { aborting.remove(target) }
        if let failed = await EngineGestureRun.failure(
            engine: engine, command: "abort",
            arguments: ["abort", "--project", target.project.rawValue, "--attempt", target.attemptID]
        ) {
            failure = failed
        }
    }

    func isAborting(_ target: AbortTarget) -> Bool {
        aborting.contains(target)
    }
}

/// What the Sidebar and the Inspector need to offer Abort Attempt, handed down by the window through the
/// environment so neither owns a confirmation of its own.
struct AttemptAbortControl {
    /// Whether Abort Attempt is offered for this Attempt of this Project.
    var canAbort: @MainActor (ProjectID, RunningAttempt) -> Bool = { _, _ in false }
    /// Whether an abort of this Attempt is in flight.
    var isAborting: @MainActor (ProjectID, RunningAttempt) -> Bool = { _, _ in false }
    /// Asks the window to confirm aborting this Attempt of this Project.
    var request: @MainActor (ProjectID, RunningAttempt) -> Void = { _, _ in }
}

/// An Abort Attempt waiting for the Operator's confirmation. It names its own Project, so confirming
/// aborts exactly the Attempt that was asked for.
struct PendingAttemptAbort: Identifiable {
    let project: ProjectID
    let attempt: RunningAttempt

    var id: AbortTarget { AbortTarget(project: project, attemptID: attempt.id) }
}
