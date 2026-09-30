import Domain
import Pulse
import SwiftUI

/// The Pulse's Feature group: the in-flight Feature's `title`, `state` and `rollup_state`, and its Repo
/// Lanes with pull request chips. The Feature and each Repo open in the Inspector; a pull request chip
/// opens the pull request on GitHub. There is no settle CTA here: settle and merge stay in Linear/GitHub.
///
/// `state`, `rollupState` and a pull request's `state` are nil from a Journal read — they live in
/// Linear, Engine's `FeatureRollUp` and GitHub respectively, none of which the app may reach here — so
/// the group states `state` and `rollupState` as unknown rather than inventing one. A pull request's own
/// state is a per-chip detail, so it is simply omitted when unknown.
struct FeatureGroup: View {
    let feature: FeatureInFlight?
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let feature {
                    FeatureHeader(feature: feature) { openDestination(.inspector(.feature(feature.id))) }
                    ForEach(feature.lanes) { lane in
                        FeatureLaneRow(lane: lane, openDestination: openDestination)
                            .accessibilityIdentifier("feature-lane-\(lane.repo)")
                    }
                } else {
                    Label("No Feature in flight", systemImage: "flag")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("feature-absence")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Feature", systemImage: "flag")
        }
        .accessibilityIdentifier("pulse-feature")
    }
}

/// The Feature's title, `state` and `rollup_state`. The title opens the Feature's detail in the
/// Inspector.
private struct FeatureHeader: View {
    let feature: FeatureInFlight
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: open) {
                Text(feature.displayTitle).lineLimit(1)
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("feature-title")
            HStack(spacing: 6) {
                Text(feature.displayState)
                if let rollupState = feature.rollupState {
                    PulseCountBadge(text: rollupState.rawValue, tint: rollupState.tint)
                } else {
                    Text("rollup state unknown")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("feature-state")
        }
    }
}

/// One Repo Lane: the Repo (opens in the Inspector), its Card progress, its lane state, and its pull
/// request chip while one exists.
private struct FeatureLaneRow: View {
    let lane: RepoLaneSnapshot
    let openDestination: @MainActor (PulseDestination) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(lane.repo) { openDestination(.inspector(.repo(lane.repo))) }
                .buttonStyle(.link)
            Text("\(lane.cardsDone)/\(lane.cardsTotal)")
                .font(.caption)
                .foregroundStyle(.secondary)
            PulseCountBadge(text: lane.state.rawValue, tint: lane.state.tint)
            if let pullRequest = lane.pullRequest {
                Button(pullRequest.displayLabel) {
                    openDestination(.pullRequest(repo: lane.repo, number: pullRequest.number))
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("feature-lane-\(lane.repo)-pull-request")
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: For display

private extension FeatureInFlight {
    /// The Feature's title, or its id while the title is not known.
    var displayTitle: String { title ?? id }

    /// The Feature's workflow state, or a stated unknown while it is nil (it lives in Linear).
    var displayState: String { state ?? "state unknown" }
}

private extension RollUpState {
    var tint: Color {
        switch self {
        case .authoring: .secondary
        case .running: .green
        case .needsYou, .partialLanding: .orange
        case .blocked: .red
        case .verified: .purple
        }
    }
}

private extension LaneState {
    var tint: Color {
        switch self {
        case .running: .green
        case .blocked: .red
        case .waitingOnYou: .orange
        case .landed: .purple
        }
    }
}

private extension PullRequestChip {
    /// `#42 open`, or just `#42` while the pull request's own state is unknown (it lives in GitHub).
    var displayLabel: String {
        ["#\(number)", state?.rawValue].compactMap { $0 }.joined(separator: " ")
    }
}
