import Domain
import Engine
import Foundation

/// ``RunResultReading`` over the run directory layout ``CLIAdapterDispatch`` owns (loop-state/reclaim-
/// an-expired-lease, P8.10): the `<attemptID>-<pass>` directory with the latest modification date is
/// the dead run's last-attempted pass. A rehearsal Night writes no result files, so this simply finds
/// none — the sweep falls back to the event log's last recorded pass step and, failing that, to
/// Crashed-Unknown — so the same reader is bound in both modes.
public struct RunDirectoryResultReader: RunResultReading {
    let runsDirectory: URL

    public init(runsDirectory: URL) {
        self.runsDirectory = runsDirectory
    }

    /// One candidate pass directory, with the modification date used to pick the latest.
    private struct Candidate {
        let pass: RunPass
        let url: URL
        let modified: Date
    }

    public func lastPass(runID: RunID, issueID: String, attemptID: Int64) throws -> RunPassResult? {
        var latest: Candidate?
        for pass in RunPass.allCases {
            let directory = CLIAdapterDispatch.runDirectory(
                runsDirectory: runsDirectory, runID: runID, issueID: issueID, attemptID: attemptID, pass: pass
            )
            guard
                let attributes = try? FileManager.default.attributesOfItem(
                    atPath: directory.path(percentEncoded: false)
                ),
                let modified = attributes[.modificationDate] as? Date
            else { continue }
            if latest == nil || modified > latest!.modified {
                latest = Candidate(pass: pass, url: directory, modified: modified)
            }
        }
        guard let latest else { return nil }
        let resultFile = latest.url.appending(component: "result.json", directoryHint: .notDirectory)
        let data = try? Data(contentsOf: resultFile)
        return RunPassResult(pass: latest.pass, data: data)
    }
}
