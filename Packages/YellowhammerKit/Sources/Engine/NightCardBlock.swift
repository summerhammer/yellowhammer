import Domain
import Foundation
import Journal

/// Renders the Night Card's Managed Block from the Journal — deterministically, so the hash the
/// Outbox compares against is stable across replays. Nothing here reads the clock: every timestamp
/// comes from the Journal's own recorded dates, formatted ISO-8601 UTC.
public enum NightCardBlock {
    /// The block a Night Card is created with: the Night is open, and the summary is written when
    /// the land firing at `night_end` completes it. `authoringFindings` is one line per quiet
    /// authoring reason this Night has recorded so far (P9.1) — empty for every Night Card this Act
    /// created before authoring existed, so existing rendered output is unchanged.
    public static func opened(night: NightRecord, projectID: ProjectID, authoringFindings: [String] = []) -> String {
        var lines = header(night: night, projectID: projectID)
        lines.append("")
        lines.append(
            "**Night Summary:** the Night is open. The summary is written when the land firing at " +
            "`night_end` completes this Night Card."
        )
        appendAuthoringFindings(authoringFindings, to: &lines)
        lines.append("")
        lines.append(CardManagedBlock.footer)
        return lines.joined(separator: "\n")
    }

    /// The block a Night Card is completed with: the same header, when it was completed, the Night's
    /// verdict — the idle finding this phase can carry, or a placeholder until the Night Summary lands
    /// (P12.1) — the quiet authoring findings this Night recorded (P9.1), and, when the Delta Read
    /// found any, the Waiting on You anomalies this Night.
    public static func completed(
        night: NightRecord, projectID: ProjectID, authoringFindings: [String] = [], anomalies: [String] = [],
        mainlineConflicts: [String] = [], bounds: [String] = [], standingItems: [String] = []
    ) -> String {
        var lines = header(night: night, projectID: projectID)
        if let completedAt = night.completedAt {
            lines.append("**Completed:** \(iso8601(completedAt)) at `night_end`")
        }
        lines.append("")
        switch night.verdict {
        case .idle:
            lines.append(
                "**Verdict:** idle — nothing was selectable to author (`AuthoringNoWorkAvailable`). " +
                "A quiet Night is not a failure."
            )
        case nil:
            lines.append(
                "**Verdict:** not yet computed — this build completes the Night Card with a placeholder; " +
                "the Night Summary lands with the morning report."
            )
        }
        appendAuthoringFindings(authoringFindings, to: &lines)
        appendMainlineConflicts(mainlineConflicts, to: &lines)
        if !anomalies.isEmpty {
            lines.append("")
            lines.append("**Anomalies:**")
            for anomaly in anomalies {
                lines.append("- \(anomaly)")
            }
        }
        appendBounds(bounds, to: &lines)
        appendStandingItems(standingItems, to: &lines)
        lines.append("")
        lines.append(CardManagedBlock.footer)
        return lines.joined(separator: "\n")
    }

    /// The `**Bounds:**` section (roadmap P11.6; bounds overview): this Night's proximity to
    /// `reselections_max`, `consecutive_refusals_max` and `failed_adoptions_max`, one line each — always
    /// present on a completed block, even when nothing happened this Night.
    private static func appendBounds(_ bounds: [String], to lines: inout [String]) {
        guard !bounds.isEmpty else { return }
        lines.append("")
        lines.append("**Bounds:**")
        for line in bounds {
            lines.append("- \(line)")
        }
    }

    /// The `**Standing items:**` section (roadmap P11.6): every currently promoted Refusal and Card,
    /// rendered on every completed Night Card while any exist — not only the Night of promotion.
    private static func appendStandingItems(_ items: [String], to lines: inout [String]) {
        guard !items.isEmpty else { return }
        lines.append("")
        lines.append("**Standing items:**")
        for item in items {
            lines.append("- \(item)")
        }
    }

    /// Appends the authoring section when there is anything to say. Called with an empty array by
    /// every pre-P9.1 render path, so existing rendered output is untouched.
    private static func appendAuthoringFindings(_ findings: [String], to lines: inout [String]) {
        guard !findings.isEmpty else { return }
        lines.append("")
        lines.append("**Authoring:**")
        for finding in findings {
            lines.append("- \(finding)")
        }
    }

    private static func appendMainlineConflicts(_ conflicts: [String], to lines: inout [String]) {
        guard !conflicts.isEmpty else { return }
        lines.append("")
        lines.append("**Mainline Conflicts:**")
        for conflict in conflicts {
            lines.append("- \(conflict)")
        }
    }

    private static func header(night: NightRecord, projectID: ProjectID) -> [String] {
        [
            "## Night \(night.nightStart)",
            "",
            "**Project:** `\(projectID)`",
            "**Mode:** \(night.mode.rawValue)",
            "**Opened:** \(iso8601(night.openedAt))"
        ]
    }

    private static func iso8601(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
