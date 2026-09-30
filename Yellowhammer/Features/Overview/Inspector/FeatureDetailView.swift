import Domain
import Pulse
import SwiftUI

/// The Inspector's Feature detail: the in-flight Feature and each of its Repo Lanes with its member
/// Cards and pull request chip, all read from the Pulse snapshot. `title`, `state` and `rollup_state`
/// are stated as unknown while the snapshot does not have them, as the Pulse's Feature group does.
///
/// Read-only. Settle and merge stay in Linear and GitHub: the one way out opens the Feature Issue.
struct FeatureDetailView: View {
    let feature: FeatureInFlight
    let decisionCardIDs: Set<String>
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        InspectorPane(
            kind: "Feature",
            wayOut: ("Open \(feature.id) in Linear", .linearIssue(feature.id)),
            note: "Settle and merge happen in Linear and GitHub, never here.",
            identifier: "feature-detail"
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text(feature.title ?? feature.id)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("feature-detail-title")
                if feature.title != nil {
                    Text(feature.id).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(feature.state ?? "state unknown")
                    if let rollupState = feature.rollupState {
                        PulseCountBadge(text: rollupState.rawValue, tint: rollupState.tint)
                    } else {
                        Text("rollup state unknown")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("feature-detail-state")
            }
            .textSelection(.enabled)

            if feature.lanes.isEmpty {
                Label("No Repo Lane yet", systemImage: "square.stack.3d.up.slash")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("feature-detail-no-lanes")
            }
            ForEach(feature.lanes) { lane in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button(lane.repo) { openDestination(.inspector(.repo(lane.repo))) }
                            .buttonStyle(.link)
                            .font(.headline)
                        PulseCountBadge(text: lane.state.rawValue, tint: lane.state.tint)
                        Text("\(lane.cardsDone)/\(lane.cardsTotal)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    if let pullRequest = lane.pullRequest {
                        Button(pullRequest.label) {
                            openDestination(.pullRequest(repo: lane.repo, number: pullRequest.number))
                        }
                        .buttonStyle(.link)
                    }
                    LaneCardList(cards: lane.cards, decisionCardIDs: decisionCardIDs)
                }
                .accessibilityIdentifier("feature-detail-lane-\(lane.repo)")
            }
        }
    }
}
