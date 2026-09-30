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
        guard let last = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              let findings = try? JSONDecoder().decode([DoctorFindingRow].self, from: Data(last.utf8))
        else {
            return nil
        }
        let flags = findings.compactMap(\.flag)
        return HealthFlagKind.allCases.flatMap { kind in flags.filter { $0.kind == kind } }
    }
}

/// One row of `yh doctor --json`. A local mirror: `Pulse` does not link `EngineCommand`.
private struct DoctorFindingRow: Decodable {
    let check: String
    let subject: String
    let severity: String
    let message: String

    var flag: HealthFlag? {
        kind.map { HealthFlag(kind: $0, detail: message) }
    }

    private var kind: HealthFlagKind? {
        switch (check, subject, severity) {
        // Warned both when the configured Operator identity is no longer a candidate and when none is
        // configured: either way Waiting on You issues go unassigned (OQ66).
        case ("linear", "operator", "warning"):
            .staleOperatorIdentity
        // No Installation token pair at all.
        case ("linear", "installation", "failure"):
            .appInstallationRevoked
        // The finding has no reason code, so revocation is told from "cannot be reached" by its wording.
        case ("linear", "authorization", "failure") where message.contains("revoked"):
            .appInstallationRevoked
        case ("probes", _, "failure"):
            .probeFailure
        default:
            nil
        }
    }
}
