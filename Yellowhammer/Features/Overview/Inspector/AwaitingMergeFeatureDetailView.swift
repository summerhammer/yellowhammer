import Domain
import Pulse
import SwiftUI

/// The Inspector's detail of a Feature in the Unmerged Feature Stack: one section per pushed repository with
/// its merge state, Feature Branch, what it is stacked on, its pull request and that pull request's last observed
/// state (app/land-on-the-sidebar-and-pulse `#awaiting-merge` and `#pull-request-state`). Read-only: merging
/// happens in GitHub, and Yellowhammer only observes it. The one way out opens the Feature Issue.
struct AwaitingMergeFeatureDetailView: View {
    let feature: AwaitingMergeFeature
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        InspectorPane(
            kind: "Feature",
            systemImage: "square.stack.3d.up.fill",
            style: ThemeShapeStyle<Color>.info,
            title: feature.displayIdentifier,
            subtitle: subtitle,
            titleIdentifier: "awaiting-merge-detail-title",
            wayOut: feature.link.map { ("Open \($0.identifier) in Linear", .linearIssue($0.url)) },
            note: "Merging happens in GitHub. Each pull request shows the state Yellowhammer last read.",
            identifier: "awaiting-merge-detail"
        ) {
            EmptyView()
        } content: {
            ForEach(feature.repositories) { repository in
                Section {
                    // On the row, not the Section: a container's identifier replaces its children's.
                    Label(repository.repo, systemImage: DomainSymbol.repo)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("awaiting-merge-detail-repo-\(repository.repo)")
                    LabeledContent("Mainline") {
                        Text(repository.merged ? "in mainline" : "not in mainline")
                    }
                    if let observation = repository.pullRequestObservation {
                        LabeledContent("Pull request state") {
                            // On the value, not the LabeledContent: there the label is what the identifier reads.
                            Text(observation.line)
                                .accessibilityIdentifier("awaiting-merge-detail-\(repository.repo)-pull-request-state")
                        }
                        .help(observation.help)
                    }
                    if let branch = repository.branch {
                        LabeledContent("Feature Branch") {
                            Text(branch).textSelection(.enabled)
                        }
                    }
                    if let stackedOn = repository.stackedOn {
                        LabeledContent("Stacked on") {
                            Text(stackedOn).textSelection(.enabled)
                        }
                    }
                    if let pullRequest = repository.pullRequest {
                        LabeledContent("Pull request") {
                            PullRequestLink(pullRequest: pullRequest, openDestination: openDestination)
                        }
                    }
                }
            }
        }
    }

    /// `Awaiting merge · 1 of 2 merged · landed tonight`.
    private var subtitle: String {
        var line = "Awaiting merge \u{00B7} \(feature.mergedCount) of \(feature.pushedCount) merged"
        if feature.landedTonight { line += " \u{00B7} landed tonight" }
        return line
    }
}
