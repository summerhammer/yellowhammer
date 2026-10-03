import Domain
import Foundation

extension HealthFlag {
    /// The Health group's flags, read from the output of `yh doctor --json`: stale Operator identity,
    /// App Installation revoked, and probe failures, in `HealthFlagKind` order. Each flag's detail is the
    /// finding's own message, so the app invents no wording.
    ///
    /// `yh doctor --json` prints its findings as one JSON array on its last line. Nil when that line is
    /// missing or is not the array, so the group says `yh doctor` was not read rather than "no flags".
    /// A finding that is none of the three flags (git, `launchd`, a Linear that cannot be reached) is not
    /// a Health flag, and is left to `yh doctor` itself.
    public static func read(doctorOutput lines: [String]) -> [HealthFlag]? {
        guard let findings = DoctorFindingRow.decodeLastLine(lines) else {
            return nil
        }
        let flags = findings.compactMap(flag(for:))
        return HealthFlagKind.allCases.flatMap { kind in flags.filter { $0.kind == kind } }
    }

    private static func flag(for row: DoctorFindingRow) -> HealthFlag? {
        kind(of: row).map { HealthFlag(kind: $0, detail: row.message) }
    }

    private static func kind(of row: DoctorFindingRow) -> HealthFlagKind? {
        switch (row.check, row.subject, row.severity) {
        // Warned both when the configured Operator identity is no longer a candidate and when none is
        // configured: either way Waiting on You issues go unassigned (OQ66).
        case ("linear", "operator", "warning"):
            .staleOperatorIdentity
        // No Installation token pair at all.
        case ("linear", "installation", "failure"):
            .appInstallationRevoked
        // The finding has no reason code, so revocation is told from "cannot be reached" by its wording.
        case ("linear", "authorization", "failure") where row.message.contains("revoked"):
            .appInstallationRevoked
        case ("probes", _, "failure"):
            .probeFailure
        default:
            nil
        }
    }
}
