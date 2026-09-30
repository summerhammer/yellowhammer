import Domain
import Pulse
import SwiftUI

/// The Inspector's Repo detail: one configured Repo, its lane in the in-flight Feature while it is in
/// one, that lane's member Cards and its running Attempt. A Repo with no lane states that it is not in
/// the Feature's lane, so the pane is never blank. Read from the Pulse snapshot.
///
/// Read-only. The one way out is the lane's pull request on GitHub, while there is one.
struct RepoDetailView: View {
    let repo: String
    let lane: RepoLaneSnapshot?
    let attempt: RunningAttempt?
    let decisionCardIDs: Set<String>
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        InspectorPane(
            kind: "Repo",
            wayOut: lane?.pullRequest.map {
                ("Open #\($0.number) on GitHub", .pullRequest(repo: repo, number: $0.number))
            },
            note: nil,
            identifier: "repo-detail"
        ) {
            Text(repo)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .accessibilityIdentifier("repo-detail-name")
            if let lane {
                HStack(spacing: 6) {
                    PulseCountBadge(text: lane.state.rawValue, tint: lane.state.tint)
                    Text("\(lane.cardsDone) of \(lane.cardsTotal) Cards done")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("repo-detail-lane")
                LaneCardList(cards: lane.cards, decisionCardIDs: decisionCardIDs)
            } else {
                Label("Not in the Feature\u{2019}s lane", systemImage: "minus.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("repo-detail-no-lane")
            }
            if let attempt {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Running Attempt").font(.caption).foregroundStyle(.secondary)
                    Button("\(attempt.cardID)  \(attempt.cardTitle)") {
                        openDestination(.inspector(.attempt(attempt.id)))
                    }
                    .buttonStyle(.link)
                    .lineLimit(1)
                }
                .accessibilityIdentifier("repo-detail-attempt")
            }
        }
    }
}
