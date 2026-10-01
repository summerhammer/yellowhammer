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
        var lines: [String] = []
        do {
            let status = try await engine.run(arguments: ["stop", "--project", project.rawValue]) { lines.append($0) }
            if status != 0 { failure = Self.tail(lines, fallback: "yh stop exited with status \(status).") }
        } catch {
            failure = Self.tail(lines, fallback: "\(error)")
        }
    }

    func isStopping(_ project: ProjectID?) -> Bool {
        project.map(stopping.contains) ?? false
    }

    private static func tail(_ lines: [String], fallback: String) -> String {
        lines.isEmpty ? fallback : lines.suffix(5).joined(separator: "\n")
    }
}
