import Domain
import Foundation

extension HealthFlag {
    /// One Project's Health flags, read from the output of `yh doctor --json`. Nil when the output has no
    /// findings array; see `flags(in:for:)` for which findings count.
    ///
    /// `yh doctor --json` prints its findings as one JSON array on its last line. Nil when that line is
    /// missing or is not the array, so the group says `yh doctor` was not read rather than "no flags".
    public static func read(doctorOutput lines: [String], project: ProjectID) -> [HealthFlag]? {
        DoctorFindingRow.decodeLastLine(lines).map { flags(in: $0, for: project) }
    }

    /// The flags `project`'s Health group shows: stale Operator identity, Board Connection revoked, refused
    /// Code Hosting Connection, and probe failures, in `HealthFlagKind` order. Each flag's detail is the finding's own message, so the
    /// app invents no wording.
    ///
    /// - Probe failures have no installation scope (Agent CLIs are machine-wide), so they appear on every
    ///   Project.
    /// - The two installation flags and the Code Hosting Connection flag appear only when the row's `projects`
    ///   contains `project`: they are the flags of the installation or connection this Project selected,
    ///   never of one only other Projects use.
    /// - A row whose `projects` is empty (an installation or connection no Project uses) is on no Project.
    /// - An installation or connection row whose `projects` is nil is dropped, never broadcast to every Project.
    /// - A finding that is none of the four flags (git, `launchd`, a Project naming a missing
    ///   installation or connection, a Linear that cannot be reached) is not a Health flag, and is left to `yh doctor`.
    public static func flags(in rows: [DoctorFindingRow], for project: ProjectID) -> [HealthFlag] {
        let flags = rows.compactMap { flag(for: $0, project: project) }
        return HealthFlagKind.allCases.flatMap { kind in flags.filter { $0.kind == kind } }
    }

    private static func flag(for row: DoctorFindingRow, project: ProjectID) -> HealthFlag? {
        guard let kind = kind(of: row) else { return nil }
        if kind != .probeFailure, row.projects?.contains(project.rawValue) != true {
            return nil
        }
        return HealthFlag(kind: kind, detail: row.message)
    }

    private static func kind(of row: DoctorFindingRow) -> HealthFlagKind? {
        switch (row.check, row.subject, row.severity) {
        // Warned both when the configured Operator identity is no longer a candidate and when none is
        // configured: either way Waiting on You issues go unassigned (OQ66).
        case ("linear", "operator", "warning"):
            .staleOperatorIdentity
        // No Installation token pair at all.
        case ("linear", "connection", "failure"):
            .appInstallationRevoked
        // The finding has no reason code, so revocation is told from "cannot be reached" by its wording.
        case ("linear", "authorization", "failure") where row.message.contains("revoked"):
            .appInstallationRevoked
        // A refused Code Hosting Connection that this Project selects (token missing, unreadable or rejected,
        // or gh absent or logged out).
        case ("github", "credential", "failure"):
            .codeHostingConnectionRefused
        case ("probes", _, "failure"):
            .probeFailure
        default:
            nil
        }
    }
}
