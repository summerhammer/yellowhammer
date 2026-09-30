import Domain
import Foundation
import Observation

/// The Status tab's model (P14.6; OQ12 Surface 3): the app equivalent of `yh status` and `yh doctor`
/// for the window's Project. The app never computes status itself — it cannot: the app must not link
/// `EngineCommand`/`Engine` (shell, not host; CI check MB3) — so this shells the bundled `yh` out the same way
/// ``AgentCLIModel`` runs `yh probe`, which makes the app's diagnoses identical to the CLI's by
/// construction. Never passes `--fix`, `--yes` or `--probe`: those mutate (plists, the Ledger), and the
/// app only displays.
@MainActor
@Observable
final class ProjectStatusModel {
    let project: ProjectID

    private(set) var statusLines: [String] = []
    private(set) var statusExitStatus: Int32?
    private(set) var doctorLines: [String] = []
    private(set) var doctorExitStatus: Int32?
    private(set) var isRunning = false

    /// The same process-running seam ``AgentCLIModel`` runs `yh probe` through: the app never computes
    /// status itself, only `yh` does.
    private let engine = SetupEngine()

    init(project: ProjectID) {
        self.project = project
    }

    /// Runs `yh status --project <id>` then `yh doctor --project <id>` in sequence, streaming each
    /// command's merged output into its own array. Guarded against re-entry. Nothing here outlives this
    /// call: no timer, no polling, no cache beyond the view's lifetime ("Nothing resident").
    func refresh() async {
        guard !isRunning else { return }
        isRunning = true
        statusLines = []
        statusExitStatus = nil
        doctorLines = []
        doctorExitStatus = nil
        defer { isRunning = false }

        do {
            let arguments = ["status", "--project", project.rawValue]
            let status = try await engine.run(arguments: arguments) { [weak self] line in
                self?.statusLines.append(line)
            }
            statusExitStatus = status
        } catch {
            statusLines.append("\(error)")
            statusExitStatus = -1
        }

        do {
            let arguments = ["doctor", "--project", project.rawValue]
            let status = try await engine.run(arguments: arguments) { [weak self] line in
                self?.doctorLines.append(line)
            }
            doctorExitStatus = status
        } catch {
            doctorLines.append("\(error)")
            doctorExitStatus = -1
        }
    }
}
