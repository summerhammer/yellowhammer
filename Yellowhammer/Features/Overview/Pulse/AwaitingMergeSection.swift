import Domain
import Pulse
import SwiftUI

/// The Feature group's "Awaiting merge" part: the Unmerged Feature Stack U, bottom of the stack first, each
/// Feature with its per-repository merge state (proposed amendment, yellowhammer-spec#132). A row opens the
/// Feature in the Inspector and a pull request chip opens GitHub; merging itself happens in GitHub, so there
/// is no merge CTA here.
struct AwaitingMergeSection: View {
    let stack: UnmergedFeatureStack
    let inspected: PulseSelection?
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        HStack {
            Text("Awaiting merge").font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Text(stack.countText).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("feature-awaiting-merge")
        ForEach(stack.features) { feature in
            VStack(alignment: .leading, spacing: 4) {
                Button { openDestination(.inspector(.feature(feature.id))) } label: {
                    AwaitingMergeHeader(feature: feature)
                        .pulseRowHighlight(inspected == .feature(feature.id))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("feature-awaiting-merge-\(feature.id)")
                ForEach(feature.repositories) { repository in
                    AwaitingMergeRepositoryLine(
                        featureID: feature.id,
                        repository: repository,
                        openDestination: openDestination
                    )
                }
            }
        }
    }
}

/// A Feature of U: its identifier, a `landed tonight` badge when it is, and `k of N merged`.
private struct AwaitingMergeHeader: View {
    let feature: AwaitingMergeFeature

    var body: some View {
        HStack(spacing: 6) {
            Text(feature.displayIdentifier).fontWeight(.medium).font(.callout.monospaced())
            if feature.landedTonight {
                PulseCountBadge(text: "landed tonight", style: ThemeShapeStyle<Color>.info)
            }
            Spacer(minLength: 8)
            Text("\(feature.mergedCount) of \(feature.pushedCount) merged")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

/// One pushed repository of a Feature in U: the repo, whether it is in mainline, what it is stacked on, and
/// its pull request chip.
private struct AwaitingMergeRepositoryLine: View {
    let featureID: String
    let repository: AwaitingMergeRepository
    let openDestination: OpenPulseDestinationAction

    var body: some View {
        HStack(spacing: 8) {
            Label(repository.repo, systemImage: DomainSymbol.repo)
                .lineLimit(1)
                .truncationMode(.middle)
            Label(
                repository.merged ? "in mainline" : "not in mainline",
                systemImage: repository.merged ? "checkmark.circle.fill" : "circle.dashed"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let stackedOn = repository.stackedOn {
                Text("stacked on \(stackedOn)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let pullRequest = repository.pullRequest {
                PullRequestChipButton(
                    pullRequest: pullRequest,
                    identifier: "feature-awaiting-merge-\(featureID)-\(repository.repo)-pull-request",
                    openDestination: openDestination
                )
            }
        }
        .padding(.leading, 12)
    }
}

// MARK: For display

extension UnmergedFeatureStack {
    /// `m of max`, or just `m` while the Bound was not read.
    var countText: String {
        guard let unmergedFeaturesMax else { return "\(count)" }
        return "\(count) of \(unmergedFeaturesMax)"
    }

    /// `m of max awaiting merge`, or `m awaiting merge` while the Bound was not read.
    var awaitingText: String {
        "\(countText) awaiting merge"
    }
}

extension AwaitingMergeFeature {
    /// The readable identifier, else the Linear link's, else the Journal id.
    var displayIdentifier: String { issueIDForDisplay ?? link?.identifier ?? id }
}

extension FeatureInFlight {
    /// `stacked on ARC-9 in archive, ARC-8 in site` (sorted by repository), or nil when it is stacked on nothing.
    var stackedOnLine: String? {
        guard !stackedOn.isEmpty else { return nil }
        let parts = stackedOn.sorted { $0.key < $1.key }.map { "\($0.value) in \($0.key)" }
        return "stacked on " + parts.joined(separator: ", ")
    }
}
