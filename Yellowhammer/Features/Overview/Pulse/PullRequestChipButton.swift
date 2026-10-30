import Domain
import Pulse
import SwiftUI

/// A pull request's chip as a small bordered button that opens the pull request on GitHub. Shared by a Repo
/// Lane and an Awaiting merge repository line, so both look and behave alike. The identifier goes on the
/// button itself: a row's identifier would replace it. A pull request whose URL the Journal does not hold (the
/// land Act recorded none, and only the pull request read named its number) shows its number and opens nothing:
/// no URL is made up.
struct PullRequestChipButton: View {
    let pullRequest: PullRequestChip
    let identifier: String
    let openDestination: OpenPulseDestinationAction

    var body: some View {
        if let url = pullRequest.url {
            Button {
                openDestination(.pullRequest(url))
            } label: {
                label
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open pull request #\(pullRequest.number) on GitHub")
            .accessibilityIdentifier(identifier)
        } else {
            label
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Pull request #\(pullRequest.number); no link to it is recorded")
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(identifier)
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.pull")
            Text(pullRequest.label).monospacedDigit()
        }
    }
}

/// A pull request's number as an Inspector link to it on GitHub, or as plain text where no URL is recorded.
struct PullRequestLink: View {
    let pullRequest: PullRequestChip
    let openDestination: OpenPulseDestinationAction

    var body: some View {
        if let url = pullRequest.url {
            Button(pullRequest.label) { openDestination(.pullRequest(url)) }
                .buttonStyle(.link)
        } else {
            Text(pullRequest.label)
        }
    }
}

/// A pull request's last observed state, with the time it was observed, and that the latest read failed where it
/// did (app/land-on-the-sidebar-and-pulse `#pull-request-state`). Its own element beside "in mainline", never
/// inside it, with its own identifier: a coloured mark on a Label's icon is invisible to accessibility.
struct PullRequestObservationLabel: View {
    let observation: PullRequestObservation
    let identifier: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.pull")
                .foregroundStyle(observation.state.style)
                .accessibilityHidden(true)
            Text(observation.line)
            if observation.latestReadFailed {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(ThemeShapeStyle<Color>.warning)
                    .accessibilityHidden(true)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(observation.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(observation.line)
        .accessibilityIdentifier(identifier)
    }
}

extension PullRequestObservation {
    /// `pull request open · 30 Oct 2026 at 14:02`, then `· latest read failed` where it did. The date is kept: a
    /// Feature can wait in the stack for several Nights.
    var line: String {
        var parts = ["pull request \(state.words)", observedAt.formatted(date: .abbreviated, time: .shortened)]
        if latestReadFailed { parts.append("latest read failed") }
        return parts.joined(separator: " \u{00B7} ")
    }

    var help: String {
        let time = observedAt.formatted(date: .abbreviated, time: .shortened)
        let observed = "Last observed \(time) by the pull request read"
        return latestReadFailed ? observed + "; the latest read failed, so this is the last state known" : observed
    }
}
