import Domain
import Foundation
import Journal

/// Renders the Night Card's Managed Block from the Journal — deterministically, so the hash the
/// Outbox compares against is stable across replays. Nothing here reads the clock: every timestamp
/// comes from the Journal's own recorded dates, formatted ISO-8601 UTC.
public enum NightCardBlock {
    /// The block a Night Card is created with: the Night is open, and the summary is written when
    /// the land firing at `night_end` completes it.
    public static func opened(night: NightRecord, projectID: ProjectID) -> String {
        var lines = header(night: night, projectID: projectID)
        lines.append("")
        lines.append(
            "**Night Summary:** the Night is open. The summary is written when the land firing at " +
            "`night_end` completes this Night Card."
        )
        lines.append("")
        lines.append(CardManagedBlock.footer)
        return lines.joined(separator: "\n")
    }

    /// The block a Night Card is completed with: the same header, when it was completed, and the
    /// Night's verdict — the idle finding this phase can carry, or a placeholder until the Night
    /// Summary lands (P12.1).
    public static func completed(night: NightRecord, projectID: ProjectID) -> String {
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
        lines.append("")
        lines.append(CardManagedBlock.footer)
        return lines.joined(separator: "\n")
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
