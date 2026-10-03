import Pulse
import SwiftUI

/// Names the way out the Operator took, when its real destination is not wired yet: the Night Card and
/// issues open in Linear, and pull requests open on GitHub. It is a placeholder. The steps that wire
/// those ways out replace it with `openURL`, and delete it when the last one is wired.
struct WayOutNotice: View {
    let destination: PulseDestination
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.forward.app")
                .foregroundStyle(.secondary)
            Text(message)
                .accessibilityIdentifier("way-out-notice")
            Spacer()
            Button("Dismiss", action: dismiss)
        }
        .padding(10)
        .background(.bar, in: .rect(cornerRadius: 8))
        .padding()
    }

    private var message: String {
        switch destination {
        case .nightCard:
            "Opening the Night Card in Linear is not built yet."
        case let .linearIssue(id):
            "Opening \(id) in Linear is not built yet."
        case let .pullRequest(repo, number):
            "Opening pull request #\(number) of \(repo) on GitHub is not built yet."
        case .inspector, .settings, .linearWorkspaces:
            "Opening \(destination) is not built yet."
        }
    }
}
