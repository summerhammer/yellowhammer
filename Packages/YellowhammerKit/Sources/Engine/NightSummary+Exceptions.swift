import Domain
import Foundation
import Journal

// The Night Summary's `**Anomalies:**` extension, `**Crashes and reclaims:**` and `**Exceptions:**`
// sections (roadmap P12.1). A reclaimed Card is worded with the mandated phrase — "the Card is
// reclaimable, and no partial state was written as if it were complete" — never that it continues.

extension NightSummary {
    /// The `**Anomalies:**` section's lines: a Waiting on You Card the Delta Read found with no
    /// Journal record behind it, a broken Managed Block delimiter, and a Card that violates an
    /// authoring invariant. Empty when none of these happened this Night.
    public static func anomalyLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        var seen: Set<String> = []
        var lines: [String] = []
        func append(_ line: String) {
            guard seen.insert(line).inserted else { return }
            lines.append(line)
        }
        for record in try nightEvents(night: night, journal: journal) {
            switch record.event {
            case .waitingOnYouUnbacked(let issueID, _, _):
                append(
                    "`\(issueID)` was read in Waiting on You with no Journal record behind it; it was not dispatched."
                )
            case .managedBlockDelimiterBroken(let issueID):
                append(
                    "`\(issueID)`'s Managed Block delimiter was broken: the fenced block could not be " +
                        "located, so it was not rewritten this Night."
                )
            case .authoringInvariantBroken(_, let issueID, let reason):
                append("`\(issueID)` violates an authoring invariant: \(reason).")
            default:
                break
            }
        }
        return lines
    }

    /// The `**Crashes and reclaims:**` section: `nightOpenedAndDied`, `leaseReclaimed`,
    /// `cardLeaseReclaimed`/`cardReclaimed`, and `expiredCardLeasesSwept`. Empty when none of these
    /// happened this Night.
    public static func crashesAndReclaimsLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        var lines: [String] = []
        for record in try nightEvents(night: night, journal: journal) {
            switch record.event {
            case .nightOpenedAndDied(_, let nightStart):
                lines.append("Night `\(nightStart)` opened and died: it never completed, closed on resumption.")
            case .leaseReclaimed(let previousRunID, let previousAct, _):
                lines.append(
                    "The \(previousAct.rawValue) Act's Lease, held by run `\(previousRunID)`, was reclaimed: " +
                        "it expired."
                )
            case .cardLeaseReclaimed(let cardID, let previousRunID, _):
                let issueID = try journal.card(id: cardID).issueID
                lines.append(
                    "Card `\(issueID)`'s Lease, held by run `\(previousRunID)`, was reclaimed: the Card is " +
                        "reclaimable, and no partial state was written as if it were complete."
                )
            case .cardReclaimed(
                let cardID, let issueID, let previousRunID, let attemptID, let outcome, let routeExcluded
            ):
                var line = try reclaimedLine(
                    cardID: cardID, issueID: issueID, previousRunID: previousRunID, outcome: outcome,
                    journal: journal
                )
                if let attemptID, let outcome {
                    let excluded = routeExcluded ? "its Route excluded" : "its Route not excluded"
                    line += " Attempt `\(attemptID)` was classified \(outcome), \(excluded)."
                }
                lines.append(line)
            case .expiredCardLeasesSwept(_, let reclaimedCardIDs):
                guard !reclaimedCardIDs.isEmpty else { continue }
                let issueIDs = try reclaimedCardIDs.map { try journal.card(id: $0).issueID }
                lines.append(
                    "\(issueIDs.count) Card Lease\(issueIDs.count == 1 ? "" : "s") swept as expired: " +
                        "\(issueIDs.map { "`\($0)`" }.joined(separator: ", ")). Each is reclaimable, and no " +
                        "partial state was written as if it were complete."
                )
            default:
                break
            }
        }
        return lines
    }

    /// The opening of a `cardReclaimed` line: stopped by the Operator, stopped by the engine, or a plain reclaim.
    private static func reclaimedLine(
        cardID: Int64, issueID: String, previousRunID: RunID, outcome: String?, journal: JournalStore
    ) throws -> String {
        let mandated = "the Card is reclaimable, and no partial state was written as if it were complete."
        if outcome == AttemptEnding.aborted.consumedHow {
            return "Card `\(issueID)` was stopped by the Operator. Its Lease, held by run " +
                "`\(previousRunID)`, was reclaimed: \(mandated)"
        }
        if let engineStop = try journal.engineStopCause(cardID: cardID, runID: previousRunID) {
            return "Card `\(issueID)` was stopped by the engine: \(engineStop). Its Lease, held by run " +
                "`\(previousRunID)`, was left to expire and reclaimed: \(mandated)"
        }
        return "Card `\(issueID)`'s Lease, held by run `\(previousRunID)`, was reclaimed: \(mandated)"
    }

    /// The `**Exceptions:**` section: `boardWriteFailed`, `rateBudgetExhausted`, `mainlineFetchFailed`,
    /// `absentNightDetected`, `notificationDeliveryFailed` and `worktreeNameCollision`. Empty when none of
    /// these happened this Night.
    public static func exceptionLines(night: NightRecord, journal: JournalStore) throws -> [String] {
        var lines: [String] = []
        for record in try nightEvents(night: night, journal: journal) {
            switch record.event {
            case .boardWriteFailed(_, let operation, let issueID, let reason):
                let named = issueID.map { " on `\($0)`" } ?? ""
                lines.append("A board write permanently failed: \(operation)\(named) — \(reason).")
            case .rateBudgetExhausted(let degradation, let installation):
                if let installation {
                    lines.append(
                        "The board's request budget was exhausted installation-wide, on Linear workspace "
                            + "\"\(installation.name)\" (shared by every Project on that workspace's App "
                            + "Installation): \(degradation)."
                    )
                } else {
                    lines.append("The board's request budget was exhausted installation-wide: \(degradation).")
                }
            case .mainlineFetchFailed(let repository, let reason):
                lines.append("Fetching mainline for `\(repository)` failed: \(reason).")
            case .absentNightDetected(let nightStart):
                lines.append("Night `\(nightStart)` did not open: reported only, not spent against a Bound.")
            case .notificationDeliveryFailed(let notification, let reason):
                lines.append(
                    "Notification `\(notification)` delivery failed: \(reason). Fire-and-forget: never retried."
                )
            case .worktreeNameCollision(let repository, let requested, let reported):
                lines.append(
                    "A Worktree branch-name collision in `\(repository)` halted the build Act: Orca ADE made "
                        + "`\(reported)`, not `\(requested)`. Later Acts retry."
                )
            default:
                break
            }
        }
        return lines
    }
}
