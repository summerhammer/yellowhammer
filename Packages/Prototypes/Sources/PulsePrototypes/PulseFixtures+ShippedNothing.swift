#if DEBUG
import Domain
import Foundation
import Pulse

extension PulseFixtures {
    /// The invented detail line each Health flag kind shows in the Playground.
    static let healthDetails: [HealthFlagKind: String] = [
        .staleOperatorIdentity: "The Operator identity was last confirmed 41 days ago.",
        .appInstallationRevoked: "The Linear workspace revoked the Board Connection.",
        .codeHostingConnectionRefused: "Code Hosting Connection github: GitHub rejected the token.",
        .probeFailure: "codex failed its Probe: exit status 127.",
        .actFailure: "build · main: Worktree allocation failed.",
        .boardProvisioningFailure: "The board is missing a provisioned label",
        .undeliveredBoardWrites: "Linear not updated",
        .routeExcluded: "claude/fable/high — rounds-exhausted on YH-406",
        .usageLimited: "codex — 4 times, until 07:50",
        .recurringFailureCause: "YH-406: build failed — met on 3 Nights",
        .commitTrailersUnread: "2 commits unread on YH-406",
        .leftoverProcesses: "1 process left running: node",
        .managedBlockOverBudget: "1 Managed Block over the description budget: YH-406",
        .expiredCardLeasesSwept: "2 Cards reclaimed"
    ]

    /// The Night of 2026-10-31: one Card back in Todo after two Attempts rounds-exhausted on two Routes and four
    /// usage-limited ones, a closed real Night with no pull request and no Cycle landed.
    static func shippedNothingPulse(from base: PulseSnapshot) -> PulseSnapshot {
        var pulse = base
        let verdict = "Nothing shipped — 1 Card worked, no Cycle landed · 2 Attempts rounds-exhausted (YH-406)"
            + " · codex usage limit, 4 times — until 07:50"
        let headline = "Night ended without shipping: YH-406: 2 Attempts rounds-exhausted"
        var night = night(.done, verdict: verdict, dispositions: [.init(disposition: .todo, count: 1)])
        night.endedWithoutShipping = true
        night.problemHeadline = headline
        pulse.night = night
        let nightLink = PulseDestination.nightAccount(night.id, at: time(2, 10))
        pulse.health = [
            HealthFlag(
                kind: .routeExcluded, detail: "claude/fable/high — rounds-exhausted on YH-406",
                lastOccurredAt: time(2, 10), fixLink: nightLink
            ),
            HealthFlag(
                kind: .routeExcluded, detail: "claude/sonnet/medium — rounds-exhausted on YH-406",
                lastOccurredAt: time(2, 40), fixLink: nightLink
            ),
            HealthFlag(
                kind: .usageLimited, detail: "codex — 4 times, until 07:50", occurrenceCount: 4,
                lastOccurredAt: time(3, 30), fixLink: nightLink
            )
        ]
        pulse.feature = FeatureInFlight(
            id: "YH-400",
            issueIDForDisplay: "YH-400",
            title: "Recalibrate the Routing Table from the last seven Nights",
            state: "In Progress",
            rollupState: .running,
            lanes: [
                RepoLaneSnapshot(
                    repo: "yellowhammer", state: .idle, cardsDone: 0, cardsTotal: 1, pullRequest: nil,
                    cards: [LaneCard(
                        id: "YH-406", issueIDForDisplay: "YH-406",
                        title: "Revalidate the Lease before the Outbox flush", state: .todo,
                        link: issueLink("YH-406")
                    )]
                )
            ],
            link: issueLink("YH-400"),
            stallNote: "Stalled — the last Attempt on every remaining Card failed or hit a usage limit (YH-406)"
        )
        return pulse
    }
}
#endif
