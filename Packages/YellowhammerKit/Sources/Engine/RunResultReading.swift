import Domain
import Foundation

/// Locates a dead run's last-attempted pass, for the lease-reclaim sweep's defensive classification
/// (loop-state/reclaim-an-expired-lease, P8.10). This seam only finds files; it never interprets them —
/// the sweep validates whatever it returns with ``ResultFile/decode(_:expecting:)`` itself.
/// `EngineCommand` implements this over the run directory layout ``CLIAdapterDispatch`` owns (MB1: the
/// Engine never imports an adapter, so it never builds that path itself).
public protocol RunResultReading: Sendable {
    /// The dead run's last-attempted pass for `attemptID` — by convention, the `<attemptID>-<pass>` run
    /// directory with the latest modification date — or `nil` when no pass directory exists at all.
    func lastPass(runID: RunID, issueID: String, attemptID: Int64) throws -> RunPassResult?
}

/// One pass's result file, unread and unvalidated: the pass it was for, and the raw bytes of its
/// `result.json`, `nil` when the directory holds no such file.
public struct RunPassResult: Sendable {
    public let pass: RunPass
    public let data: Data?

    public init(pass: RunPass, data: Data?) {
        self.pass = pass
        self.data = data
    }
}
