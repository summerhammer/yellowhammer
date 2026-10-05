import Domain
import Foundation
import Observation

/// One Project's removal, run from Settings → the Project's pane: `yh project remove <id> --yes`. The app
/// does no removal work (ADR-001): it confirms, runs `yh`, shows `yh`'s lines verbatim and, once `yh` exits
/// 0, tells its owner to read the configuration again.
///
/// Owned by the Project's pane, so the sheet that shows it and the footer button that opens it share one
/// run. It owns its own `SetupEngine`, so a removal never competes with another model's `yh`.
@MainActor
@Observable
final class ProjectRemovalModel {
    enum Phase: Equatable {
        case idle
        case running
        /// `yh` refused or failed; the Project's file is still there and the removal can be retried.
        case failed
        /// `yh` exited 0: the Project's file is gone and its Journal was kept.
        case removed
    }

    let projectID: ProjectID
    private(set) var phase = Phase.idle
    /// `yh`'s lines of the current or last run, verbatim, as they arrived.
    private(set) var lines: [String] = []
    /// What to show after a failed run: `yh`'s lines, else the error's text, else its exit status.
    private(set) var failure: String?

    private let engine = SetupEngine()

    init(projectID: ProjectID) {
        self.projectID = projectID
    }

    /// Whether `yh` may be run at all. `yh` always acts on the real configuration, so while the app is
    /// pointed at another one (a UI test's fixture) a removal would remove a real Project of the same id,
    /// unless a stub stands in for `yh`.
    var isAvailable: Bool {
        !ConfigurationDirectory.isOverridden || SetupEngine.isStubbed
    }

    /// Runs `yh project remove <id> --yes`. Does nothing while a run is in progress, or when `yh` is not
    /// available.
    func remove() async {
        guard phase != .running, isAvailable else { return }
        phase = .running
        lines = []
        failure = nil
        let arguments = ProjectInvocation.removeArguments(project: projectID)
        do {
            let status = try await engine.run(arguments: arguments) { [weak self] line in
                self?.lines.append(line)
            }
            if status == 0 {
                phase = .removed
            } else {
                fail(lines.isEmpty ? "yh exited \(status)." : lines.joined(separator: "\n"))
            }
        } catch {
            fail(lines.isEmpty ? "\(error)" : lines.joined(separator: "\n"))
        }
    }

    /// Back to idle after a failure, so the next *Remove Project…* opens a fresh sheet.
    func reset() {
        guard phase == .failed else { return }
        phase = .idle
        lines = []
        failure = nil
    }

    /// Terminates a running `yh`.
    func terminate() {
        engine.terminate()
    }

    private func fail(_ text: String) {
        failure = text
        phase = .failed
    }
}
