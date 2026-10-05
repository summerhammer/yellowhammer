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
            systemImage: "flag.fill",
            style: feature.rollupState.map { AnyShapeStyle($0.style) } ?? AnyShapeStyle(.neutral),
            title: feature.title ?? (feature.issueIDForDisplay ?? feature.id),
            subtitle: feature.issueIDForDisplay ?? (feature.link?.identifier ?? feature.id),
            titleIdentifier: "feature-detail-title",
            wayOut: feature.link.map { ("Open \($0.identifier) in Linear", .linearIssue($0.url)) },
            note: "Settle and merge happen in Linear and GitHub, never here.",
            identifier: "feature-detail"
        ) {
            Group {
                if let state = feature.state {
                    PulseCountBadge(text: state, style: .neutral)
                } else {
                    Text("state unknown").font(.caption).foregroundStyle(.secondary)
                }
                if let rollupState = feature.rollupState {
                    PulseCountBadge(text: rollupState.rawValue, style: rollupState.style)
                } else {
                    Text("rollup state unknown").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("feature-detail-state")
        } content: {
            if feature.lanes.isEmpty {
                Section("Repo Lanes") {
                    Label("No Repo Lane yet", systemImage: "square.stack.3d.up.slash")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("feature-detail-no-lanes")
                }
            }
            ForEach(feature.lanes) { lane in
                Section {
                    HStack(spacing: 8) {
                        Button(lane.repo) { openDestination(.inspector(.repo(lane.repo))) }
                            .buttonStyle(.link)
                            .fontWeight(.semibold)
                        Spacer(minLength: 8)
                        Text("\(lane.cardsDone)/\(lane.cardsTotal)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        PulseCountBadge(text: lane.state.rawValue, style: lane.state.style)
                    }
                    .accessibilityIdentifier("feature-detail-lane-\(lane.repo)")
                    if let pullRequest = lane.pullRequest {
                        LabeledContent("Pull request") {
                            Button(pullRequest.label) {
                                openDestination(.pullRequest(pullRequest.url))
                            }
                            .buttonStyle(.link)
                        }
                    }
                    LaneCardList(cards: lane.cards, decisionCardIDs: decisionCardIDs)
                }
            }
        }
    }
}
