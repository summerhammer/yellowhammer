import Domain
import Pulse
import SwiftUI

/// The Inspector's Attempt detail: one running Attempt, from the Pulse snapshot. The status is one line
/// of status, never output from the agent CLI, and is stated as unknown while the snapshot has none.
///
/// Read-only. The one way out opens the Attempt's Card in Linear.
struct AttemptDetailView: View {
    let attempt: RunningAttempt
    let asOf: Date
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        InspectorPane(
            kind: "Attempt",
            wayOut: ("Open \(attempt.cardID) in Linear", .linearIssue(attempt.cardID)),
            note: nil,
            identifier: "attempt-detail"
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Button("\(attempt.cardID)  \(attempt.cardTitle)") {
                    openDestination(.inspector(.card(attempt.cardID)))
                }
                .buttonStyle(.link)
                .font(.title3.weight(.semibold))
                .accessibilityIdentifier("attempt-detail-card")
            }
            InspectorFact(label: "Repo", value: attempt.repo)
            InspectorFact(label: "Route", value: attempt.route)
            InspectorFact(label: "Round", value: String(attempt.round))
            InspectorFact(
                label: "Running for",
                value: Duration.seconds(max(0, asOf.timeIntervalSince(attempt.startedAt)))
                    .formatted(.units(allowed: [.hours, .minutes], width: .narrow))
            )
            InspectorFact(label: "Started", value: attempt.startedAt.formatted(date: .abbreviated, time: .shortened))
            InspectorFact(label: "Status", value: attempt.status ?? "status unknown")
        }
    }
}
