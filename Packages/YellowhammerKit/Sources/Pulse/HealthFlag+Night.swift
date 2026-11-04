import Domain
import Foundation

extension HealthFlag {
    /// The Health flags a Night's own events raise, in a stable order: excluded Routes, repeated usage limits,
    /// recurring failure causes, then the notes. Every one opens the Night's account at its first occurrence.
    ///
    /// A usage limit is a flag only when it repeated (two or more times for one CLI); a single one is a deferral and
    /// reads only in the verdict. Unread commit trailers are one flag for the whole Night, naming each Card.
    public static func nightFlags(_ outcome: NightOutcome, nightID: Int64) -> [HealthFlag] {
        var flags: [HealthFlag] = outcome.excludedRoutes.map {
            nightFlag(
                .routeExcluded, "\($0.route) — \($0.reason) on \($0.cardNames.joined(separator: ", "))",
                $0.occurrence, nightID
            )
        }
        for limit in outcome.usageLimits where limit.occurrence.count >= 2 {
            let until = limit.until.formatted(date: .omitted, time: .shortened)
            flags.append(nightFlag(
                .usageLimited, "\(limit.cli) — \(limit.occurrence.count) times, until \(until)",
                limit.occurrence, nightID
            ))
        }
        flags += outcome.recurringCauses.map {
            nightFlag(
                .recurringFailureCause, "\($0.cardName): \($0.cause) — met on \($0.recurrenceCount) Nights",
                $0.occurrence, nightID
            )
        }
        return flags + noteFlags(outcome, nightID: nightID)
    }

    private static func nightFlag(
        _ kind: HealthFlagKind, _ detail: String, _ occurrence: Occurrence, _ nightID: Int64
    ) -> HealthFlag {
        HealthFlag(
            kind: kind, detail: detail, occurrenceCount: occurrence.count, lastOccurredAt: occurrence.lastAt,
            fixLink: .nightAccount(nightID, at: occurrence.firstAt)
        )
    }

    private static func noteFlags(_ outcome: NightOutcome, nightID: Int64) -> [HealthFlag] {
        var flags: [HealthFlag] = []
        if let note = outcome.unreadTrailers {
            let commits = NightStanding.counted(note.occurrence.count, "commit")
            flags.append(nightFlag(
                .commitTrailersUnread, "\(commits) unread on \(note.details.joined(separator: ", "))",
                note.occurrence, nightID
            ))
        }
        if let note = outcome.unattributedLeftovers {
            let processes = NightStanding.counted(note.occurrence.count, "process", plural: "processes")
            flags.append(nightFlag(
                .leftoverProcesses, "\(processes) left running: \(note.details.joined(separator: ", "))",
                note.occurrence, nightID
            ))
        }
        if let note = outcome.overBudgetBlocks {
            let blocks = NightStanding.counted(note.occurrence.count, "Managed Block")
            flags.append(nightFlag(
                .managedBlockOverBudget,
                "\(blocks) over the description budget: \(note.details.joined(separator: ", "))",
                note.occurrence, nightID
            ))
        }
        if let note = outcome.sweptCardLeases {
            let cards = NightStanding.counted(note.occurrence.count, "Card")
            flags.append(nightFlag(.expiredCardLeasesSwept, "\(cards) reclaimed", note.occurrence, nightID))
        }
        return flags
    }
}
