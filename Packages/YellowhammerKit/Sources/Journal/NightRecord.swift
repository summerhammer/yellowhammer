import Domain
import Foundation

/// One Night of this Project as the Journal records it: one run of the Shift for one Project, from
/// its first Act firing to its close. `projectID` is first-class on the row (OQ52), even though a
/// Journal holds one Project's Nights only, so the row names its Project without deriving it.
public struct NightRecord: Equatable, Sendable {
    public let id: Int64
    public let projectID: ProjectID
    public let nightStart: NightStart
    public let mode: NightMode
    public let state: NightState
    public let nightCardIssueID: String?
    /// The Night Card's human-readable identifier (e.g. `ARC-20`), recorded for display.
    public internal(set) var nightCardIssueIDForDisplay: String?
    public let openedAt: Date
    /// When the Night was closed in the Journal; `closeReason` says how. Nil while it is open.
    public let completedAt: Date?
    public let closeReason: NightCloseReason?
    /// The Night Summary's constant-time verdict line (OQ13); nil until something writes one.
    /// `idle` is the only value this phase writes — the author Act finding nothing selectable.
    public let verdict: NightVerdict?
    /// When this Night's morning was triaged (roadmap P10.8/P10.9; spec: morning-report/triage-the-
    /// morning): written at the Operator's settle (P10.9) or on observing a Partial
    /// Landing's merge closure (P10.8). The one field a closed Night may still change.
    public let triagedAt: Date?
    /// The Night Card's Linear `identifier` (e.g. `YH-142`), recorded by the Delta Read; nil until then
    /// (issue #230).
    public internal(set) var nightCardIssueKey: String?
    /// The Night Card's board URL as Linear gave it, recorded with ``nightCardIssueKey``; nil until then.
    public internal(set) var nightCardIssueURL: String?

    public init(
        id: Int64,
        projectID: ProjectID,
        nightStart: NightStart,
        mode: NightMode,
        state: NightState,
        nightCardIssueID: String?,
        nightCardIssueIDForDisplay: String? = nil,
        openedAt: Date,
        completedAt: Date?,
        closeReason: NightCloseReason?,
        verdict: NightVerdict?,
        triagedAt: Date?,
        nightCardIssueKey: String? = nil,
        nightCardIssueURL: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.nightStart = nightStart
        self.mode = mode
        self.state = state
        self.nightCardIssueID = nightCardIssueID
        self.nightCardIssueIDForDisplay = nightCardIssueIDForDisplay
        self.openedAt = openedAt
        self.completedAt = completedAt
        self.closeReason = closeReason
        self.verdict = verdict
        self.triagedAt = triagedAt
        self.nightCardIssueKey = nightCardIssueKey
        self.nightCardIssueURL = nightCardIssueURL
    }

    public init(
        id: Int64,
        projectID: ProjectID,
        nightStart: NightStart,
        mode: NightMode,
        state: NightState,
        nightCardIssueID: String?,
        openedAt: Date,
        completedAt: Date?,
        closeReason: NightCloseReason?,
        verdict: NightVerdict?,
        triagedAt: Date?,
        nightCardIssueKey: String? = nil,
        nightCardIssueURL: String? = nil
    ) {
        self.init(
            id: id,
            projectID: projectID,
            nightStart: nightStart,
            mode: mode,
            state: state,
            nightCardIssueID: nightCardIssueID,
            nightCardIssueIDForDisplay: nil,
            openedAt: openedAt,
            completedAt: completedAt,
            closeReason: closeReason,
            verdict: verdict,
            triagedAt: triagedAt,
            nightCardIssueKey: nightCardIssueKey,
            nightCardIssueURL: nightCardIssueURL
        )
    }

    public var isOpen: Bool { state == .opened }
}

/// What an Act learns when it opens its Night.
public struct NightOpening: Equatable, Sendable {
    /// The Night this Act belongs to: recorded by this call, or found already recorded.
    public let night: NightRecord
    /// True when this call recorded the Night, i.e. this run is the first Act of the Night.
    public let isFirstAct: Bool
    /// Nights this Project left open with no completion, closed by this call as opened-and-died.
    public let openedAndDied: [NightRecord]
    /// The Nights the audit found missing, ascending; empty on a repeat open.
    public let absentNights: [NightStart]
}
