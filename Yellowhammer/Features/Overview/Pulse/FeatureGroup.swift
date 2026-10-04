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
    /// What the Inspector shows, so the Feature or Repo it names is marked.
    let inspected: PulseSelection?
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        PulseCard(group: .feature, summary: PulseGroup.summary(of: feature)) {
            if let feature {
                Button { openDestination(.inspector(.feature(feature.id))) } label: {
                    FeatureHeader(feature: feature)
                        .pulseRowHighlight(inspected == .feature(feature.id))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("feature-title")
                if feature.lanes.isEmpty {
                    Label("No Repo Lane yet", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("feature-lanes-absence")
                } else {
                    ForEach(feature.lanes) { lane in
                        FeatureLaneRow(lane: lane, openDestination: openDestination)
                            .pulseRowHighlight(inspected == .repo(lane.repo))
                            .accessibilityIdentifier("feature-lane-\(lane.repo)")
                    }
                }
            } else {
                Label("No Feature in flight", systemImage: "flag.slash")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("feature-absence")
            }
        }
        .accessibilityIdentifier("pulse-feature")
    }
}

/// The Feature's title over its id, `state` and `rollup_state`. The whole header opens the Feature's
/// detail in the Inspector.
private struct FeatureHeader: View {
    let feature: FeatureInFlight

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(feature.displayTitle)
                .fontWeight(.medium)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                Text(feature.id).font(.caption.monospaced()).foregroundStyle(.secondary)
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
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("feature-state")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One Repo Lane: the Repo (opens in the Inspector), its Card progress, its lane state, and its pull
/// request chip while one exists.
private struct FeatureLaneRow: View {
    let lane: RepoLaneSnapshot
    let openDestination: @MainActor (PulseDestination) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button { openDestination(.inspector(.repo(lane.repo))) } label: {
                Label(lane.repo, systemImage: DomainSymbol.repo).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            ProgressView(value: Double(lane.cardsDone), total: Double(max(lane.cardsTotal, 1)))
                .frame(width: 64)
                .tint(lane.state.style)
                .accessibilityHidden(true)
            Text("\(lane.cardsDone)/\(lane.cardsTotal)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            PulseCountBadge(text: lane.state.rawValue, style: lane.state.style)
            if let pullRequest = lane.pullRequest {
                Button {
                    openDestination(.pullRequest(repo: lane.repo, number: pullRequest.number))
                } label: {
                    HStack(spacing: 4) {
                        if let state = pullRequest.state {
                            Image(systemName: "arrow.triangle.pull").foregroundStyle(state.style)
                        } else {
                            Image(systemName: "arrow.triangle.pull")
                        }
                        Text(pullRequest.label).monospacedDigit()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open pull request #\(pullRequest.number) on GitHub")
                .accessibilityIdentifier("feature-lane-\(lane.repo)-pull-request")
            }
        }
    }
}

// MARK: For display

private extension FeatureInFlight {
    /// The Feature's title, or its id while the title is not known.
    var displayTitle: String { title ?? id }
}
