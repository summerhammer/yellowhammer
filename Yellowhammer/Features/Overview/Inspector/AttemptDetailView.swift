import Domain
import Pulse
import SwiftUI

/// The Inspector's Attempt detail: one running Attempt, from the Pulse snapshot. The status is one line
/// of status, never output from the agent CLI, and is stated as unknown while the snapshot has none.
///
/// Not purely read-only: while the Attempt is running it offers Abort Attempt, which only asks the
/// window to confirm and then trigger `yh abort`. The app records nothing itself. The one way out opens
/// the Attempt's Card in Linear.
struct AttemptDetailView: View {
    let project: ProjectID
    let attempt: RunningAttempt
    let asOf: Date
    @Environment(\.openPulseDestination) private var openDestination
    @Environment(\.attemptAbort) private var attemptAbort

    var body: some View {
        InspectorPane(
            kind: "Attempt",
            systemImage: "gearshape.2.fill",
            style: .active,
            title: attempt.workCardTitle,
            subtitle: attempt.cardIDForDisplay ?? (attempt.cardLink?.identifier ?? attempt.cardID),
            titleIdentifier: "attempt-detail-title",
            wayOut: attempt.cardLink.map { ("Open \($0.identifier) in Linear", .linearIssue($0.url)) },
            note: nil,
            identifier: "attempt-detail"
        ) {
            PulseCountBadge(text: "Round \(attempt.round)", style: .active)
        } content: {
            Section {
                Button("\(attempt.cardIDForDisplay ?? attempt.cardID)  \(attempt.workCardTitle)") {
                    openDestination(.inspector(.card(attempt.cardID)))
                }
                .buttonStyle(.link)
                .lineLimit(1)
                .accessibilityIdentifier("attempt-detail-card")
                InspectorFact(label: "Repo", value: attempt.repo)
                InspectorFact(label: "Route", value: attempt.route)
                InspectorFact(label: "Round", value: String(attempt.round))
                InspectorFact(
                    label: "Running for",
                    value: Duration.seconds(max(0, asOf.timeIntervalSince(attempt.startedAt)))
                        .formatted(.units(allowed: [.hours, .minutes], width: .narrow))
                )
                InspectorFact(
                    label: "Started", value: attempt.startedAt.formatted(date: .abbreviated, time: .shortened)
                )
                InspectorFact(label: "Status", value: attempt.status ?? "status unknown")
            }
            if attemptAbort.isAborting(project, attempt) || attemptAbort.canAbort(project, attempt) {
                Section { abortControl }
            }
        }
    }

    @ViewBuilder private var abortControl: some View {
        if attemptAbort.isAborting(project, attempt) {
            ProgressView().controlSize(.small)
        } else if attemptAbort.canAbort(project, attempt) {
            Button("Abort Attempt", role: .destructive) { attemptAbort.request(project, attempt) }
                .accessibilityIdentifier("attempt-detail-abort")
        }
    }
}
