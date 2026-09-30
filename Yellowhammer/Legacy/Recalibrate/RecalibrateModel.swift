import Config
import Domain
import Foundation
import Observation

/// The Recalibrate tab's model (P14.7): this Project's Bounds, this Night's proximity to each, and a way
/// to re-set a Bound's value or launch a rehearsal Night. The app never computes proximity itself —
/// `yh recalibrate --project <id> --json` does, run through ``SetupEngine``. Bound values are edited and saved through ``ProjectDetailModel`` (P14.3) — never a
/// second TOML writer.
@MainActor
@Observable
final class RecalibrateModel {
    let project: ProjectID

    /// The decoded `yh recalibrate --json` report, or nil when it has not run yet or could not be decoded.
    private(set) var report: RecalibrateReport?
    /// Raw output shown verbatim when the run failed or its output could not be decoded (like Status).
    private(set) var rawOutputLines: [String] = []
    private(set) var exitStatus: Int32?
    private(set) var isRunning = false

    /// The Bounds form, reused as-is: saving here goes through the exact same
    /// `Config/Configuration/save(_:to:in:replacing:)` path the Configuration tab uses.
    let detail: ProjectDetailModel

    private(set) var isLaunchingRehearsal = false
    private(set) var rehearsalStartedNote: String?
    private(set) var rehearsalLogURL: URL?
    private(set) var rehearsalFailure: String?

    /// The same process-running seam the Overview window runs `yh doctor` through.
    private let engine = SetupEngine()

    init(project: ProjectID, directory: URL = ConfigurationDirectory.current) {
        self.project = project
        detail = ProjectDetailModel(project: project, directory: directory)
    }

    /// Runs `yh recalibrate --project <id> --json` and decodes its last non-empty output line as
    /// ``RecalibrateReport``. On a non-zero exit or undecodable output, the raw output lines are kept
    /// instead, shown verbatim exactly like Status. Guarded against re-entry; nothing here outlives this
    /// call.
    func refresh() async {
        guard !isRunning else { return }
        isRunning = true
        report = nil
        rawOutputLines = []
        exitStatus = nil
        defer { isRunning = false }

        do {
            var lines: [String] = []
            let arguments = ["recalibrate", "--project", project.rawValue, "--json"]
            let status = try await engine.run(arguments: arguments) { lines.append($0) }
            exitStatus = status
            guard status == 0,
                  let lastLine = lines.last(where: { !$0.isEmpty }),
                  let data = lastLine.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(RecalibrateReport.self, from: data)
            else {
                rawOutputLines = lines
                return
            }
            report = decoded
        } catch {
            rawOutputLines = ["\(error)"]
            exitStatus = -1
        }
    }

    /// Saves the Bounds form (P14.3's path) and, on success, re-runs `yh recalibrate` so the displayed
    /// values and proximity reflect what was actually written. A refusal is left exactly as
    /// ``ProjectDetailModel/failure`` reports it — never a second, app-authored message.
    func save() {
        detail.save()
        guard detail.failure == nil else { return }
        Task { await refresh() }
    }

    func revert() {
        detail.revert()
    }

    /// Launches `yh rehearse --project <id>` fully detached (P14.7's done-when: it survives the app
    /// quitting). The button that triggers this is disabled only for the duration of the synchronous
    /// spawn call below — nothing is tracked afterwards, no pid, no polling.
    func confirmRehearsal() {
        rehearsalFailure = nil
        rehearsalStartedNote = nil
        rehearsalLogURL = nil
        isLaunchingRehearsal = true
        defer { isLaunchingRehearsal = false }

        let logURL = SetupEngine.rehearsalLogURL(projectID: project.rawValue)
        do {
            try engine.launchDetached(
                arguments: ["rehearse", "--project", project.rawValue], logURL: logURL
            )
            rehearsalLogURL = logURL
            rehearsalStartedNote =
                "Rehearsal Night started \u{2014} output goes to \(logURL.path(percentEncoded: false))"
        } catch {
            rehearsalFailure = "\(error)"
        }
    }
}

/// `yh recalibrate --project <id> --json`'s decoded contract: this Night's proximity (or none recorded)
/// plus every Bound's force-rank fields. Property names match the JSON keys verbatim, so no
/// `CodingKeys` are needed.
struct RecalibrateReport: Decodable, Equatable {
    let project: String
    let night: NightReading?
    let bounds: [BoundReading]

    struct NightReading: Decodable, Equatable {
        let nightStart: String
        let mode: String
        let state: String
    }

    struct BoundReading: Decodable, Equatable {
        let name: String
        let consequenceShape: String
        let consequence: String
        let value: Int
        let proximity: Int?
        let measure: String?
    }
}
