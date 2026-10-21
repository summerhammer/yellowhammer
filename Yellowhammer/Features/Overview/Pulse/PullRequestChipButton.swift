import Domain
import Pulse
import SwiftUI

/// A pull request's chip as a small bordered button that opens the pull request on GitHub. Shared by a Repo
/// Lane and an Awaiting merge repository line, so both look and behave alike. The identifier goes on the
/// button itself: a row's identifier would replace it.
struct PullRequestChipButton: View {
    let pullRequest: PullRequestChip
    let identifier: String
    let openDestination: OpenPulseDestinationAction

    var body: some View {
        Button {
            openDestination(.pullRequest(pullRequest.url))
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
        .accessibilityIdentifier(identifier)
    }
}
