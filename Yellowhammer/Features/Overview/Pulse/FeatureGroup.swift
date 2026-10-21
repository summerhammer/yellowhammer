import Domain
import Pulse
import SwiftUI

/// The Pulse's Feature group: the in-flight Feature's `title`, `state` and `rollup_state`, and its Repo
/// Lanes with pull request chips. The Feature and each Repo open in the Inspector; a pull request chip
/// opens the pull request on GitHub. There is no Done or Cancel CTA here: moving the Feature Card and merging stay in Linear/GitHub.
///
/// `state` is the Journal's own Feature state and `rollupState` the Roll-up word computed from the Journal;
/// either is stated as unknown when nil rather than invented. A returned Feature carries its clause tally
/// under the header. A pull request's `state` is nil from a Journal read — it lives in GitHub — so a chip
/// simply omits it.
struct FeatureGroup: View {
    let feature: FeatureInFlight?
    /// The Unmerged Feature Stack U: verified Features awaiting merge, shown beside the in-flight Feature
    /// (proposed amendment, yellowhammer-spec#132).
    let stack: UnmergedFeatureStack
    /// What the Inspector shows, so the Feature or Repo it names is marked.
    let inspected: PulseSelection?
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        PulseCard(group: .feature, summary: PulseGroup.summary(of: feature, stack: stack)) {
            if let feature {
                Button { openDestination(.inspector(.feature(feature.id))) } label: {
                    FeatureHeader(feature: feature)
                        .pulseRowHighlight(inspected == .feature(feature.id))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("feature-title")
                if let stackedOnLine = feature.stackedOnLine {
                    Text(stackedOnLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("feature-stacked-on")
                }
                if feature.state == "returned" {
                    ReturnedFeatureGuidance()
                        .accessibilityIdentifier("feature-returned-guidance")
                }
                if feature.lanes.isEmpty {
                    Label("No Repo Lane yet", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("feature-lanes-absence")
                } else {
                    ForEach(feature.lanes) { lane in
                        FeatureLaneRow(lane: lane, openDestination: openDestination)
                            .pulseRowHighlight(inspected == .repo(lane.repo))
                    }
                }
            } else if stack.isEmpty {
                Label("No Feature in flight", systemImage: "flag.slash")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("feature-absence")
            } else if stack.isFull {
                Label(
                    "Authoring waits for a merge \u{2014} the unmerged Feature stack is full (\(stack.countText))",
                    systemImage: "square.stack.3d.up.fill"
                )
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("feature-stack-full")
            } else {
                Label("The in-flight slot is free", systemImage: "flag.slash")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("feature-slot-free")
            }
            if !stack.isEmpty {
                AwaitingMergeSection(stack: stack, inspected: inspected)
            }
        }
        .accessibilityIdentifier("pulse-feature")
    }
}

/// The Feature's title over its id, `state` and `rollup_state`, and its clause tally once verified. The whole header opens the Feature's
/// detail in the Inspector.
private struct FeatureHeader: View {
    let feature: FeatureInFlight

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(feature.displayTitle)
                .fontWeight(.medium)
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                Text(feature.issueIDForDisplay ?? feature.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                if let state = feature.state {
                    PulseCountBadge(text: state, style: feature.stateStyle)
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
            if let verification = feature.verification {
                Text(verification.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("feature-verification")
                if let hint = verification.notCheckedHint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("feature-verification-not-checked-hint")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One Repo Lane: the Repo (opens in the Inspector), its Card progress, its lane state, and its pull
/// request chip while one exists.
private struct FeatureLaneRow: View {
    let lane: RepoLaneSnapshot
    let openDestination: OpenPulseDestinationAction

    var body: some View {
        HStack(spacing: 8) {
            Button { openDestination(.inspector(.repo(lane.repo))) } label: {
                Label(lane.repo, systemImage: DomainSymbol.repo).lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.plain)
            // On the Repo's own button, not the row: a row's identifier replaces every child's, the pull
            // request chip's included.
            .accessibilityIdentifier("feature-lane-\(lane.repo)")
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
                PullRequestChipButton(
                    pullRequest: pullRequest,
                    identifier: "feature-lane-\(lane.repo)-pull-request",
                    openDestination: openDestination
                )
            }
        }
    }
}

// MARK: For display

private extension FeatureInFlight {
    /// The Feature's title, or its id while the title is not known.
    var displayTitle: String { title ?? (issueIDForDisplay ?? id) }
}
