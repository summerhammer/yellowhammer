import Domain
import Foundation
import Journal

// The failure events of the infrastructure family ``NightWording`` words, split from
// `NightAccount+WordingFamilies.swift` to keep each file within the lint limits. A reason is the detail,
// never the bare event name (app/land-on-the-sidebar-and-pulse#failure-line).

extension NightWording {
    /// Board write groups, Managed Blocks, Worktree loss and reconciliation, mainline conflicts and usage
    /// limits.
    func infrastructureFailures(_ event: JournalEvent) -> NightWords? {
        switch event {
        case .outboxGroupRolledBack(let groupID, let reason):
            NightWords(headline: "Board writes rolled back", detail: "\(reason) (group \(groupID))")
        case .managedBlockDelimiterBroken:
            NightWords(
                headline: "A Managed Block's delimiters were broken",
                detail: "The fenced block could not be located, so it was not rewritten this Night"
            )
        case .routeUsageLimited(let route, let cli, let until, let resetHint):
            NightWords(
                headline: "\(cli) usage limit on \(route)",
                detail: (["Backing off until \(until.formatted(date: .abbreviated, time: .shortened))"]
                    + (resetHint.map { ["the CLI reports: \($0)"] } ?? [])).joined(separator: "; ")
            )
        default:
            worktreeFailures(event)
        }
    }

    /// A Worktree lost or not reconciled, and a branch that conflicts with mainline.
    private func worktreeFailures(_ event: JournalEvent) -> NightWords? {
        switch event {
        case .worktreeLost(_, let repository, _, let path, _, let lostCommit, let lostDoneCardIDs):
            let facts = [path]
                + (lostCommit.map { ["lost commit \($0)"] } ?? [])
                + (lostDoneCardIDs.isEmpty ? [] : ["\(count(lostDoneCardIDs.count, "Done Card")) lost"])
            return NightWords(headline: "\(repository): Worktree lost", detail: facts.joined(separator: "; "))
        case .worktreeReconciliationFailed(_, let repository, let path, let reason):
            return NightWords(headline: "\(repository): Worktree reconciliation failed", detail: "\(path): \(reason)")
        case .mainlineConflictDetected(_, let repository, let paths):
            let shown = paths.prefix(3).joined(separator: ", ")
            let rest = paths.count > 3 ? " and \(paths.count - 3) more" : ""
            return NightWords(
                headline: "\(repository): conflicts with mainline", detail: paths.isEmpty ? nil : shown + rest
            )
        default:
            return nil
        }
    }
}
