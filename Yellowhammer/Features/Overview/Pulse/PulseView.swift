import Domain
import Pulse
import SwiftUI

/// The main area: the selected Project's Pulse, under that Project's name. A summary strip of five
/// figures heads tinted cards for the groups, both in the ruled order Needs you → Now → Feature →
/// Tonight / last Night → Health; each figure jumps to its group's card.
///
/// It takes one Project's snapshot and gives each group only that group's part of it. A group reports
/// each way out through `openPulseDestination`, and never opens anything itself.
struct PulseView: View {
    let project: ProjectSnapshot
    /// The instant the snapshot describes. Elapsed times are measured to this, not to the clock.
    let asOf: Date
    /// What the Inspector shows, so the row it names is marked.
    let inspected: PulseSelection?
    let deliverNow: () -> Void
    let canDeliverNow: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    PulseHeader(project: project)
                    if let failure = project.journalFailure {
                        JournalFailureNotice(failure: failure)
                    } else {
                        PulseSummaryStrip(pulse: project.pulse) { group in
                            withAnimation { proxy.scrollTo(group, anchor: .top) }
                        }
                        .padding(.bottom, 6)
                        ForEach(PulseGroup.allCases) { group in
                            card(group).id(group)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
    }

    @ViewBuilder private func card(_ group: PulseGroup) -> some View {
        let pulse = project.pulse
        switch group {
        case .needsYou: NeedsYouGroup(needsYou: pulse.needsYou, inspected: inspected)
        case .now: NowGroup(now: pulse.now, asOf: asOf, inspected: inspected)
        case .feature: FeatureGroup(feature: pulse.feature, inspected: inspected)
        case .night: NightGroup(night: pulse.night)
        case .health: HealthGroup(health: pulse.health, deliverNow: deliverNow, canDeliverNow: canDeliverNow)
        }
    }
}

/// The Project's name heading the main area, so the Pulse always says whose it is, over its status and
/// Repo count. Status falls back to the Project's `launchd` Act jobs when the Journal
/// could not be read.
private struct PulseHeader: View {
    let project: ProjectSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name)
                .font(.largeTitle.bold())
                .lineLimit(2)
                .accessibilityIdentifier("pulse-heading")
            HStack(spacing: 6) {
                Circle().fill(project.status.style).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(project.status.rawValue)
                Text("\u{00B7}")
                Text(project.repos.count == 1 ? "1 Repo" : "\(project.repos.count) Repos")
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }
}

/// Why the Pulse cannot be shown: the Project's Journal could not be read.
private struct JournalFailureNotice: View {
    let failure: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                "Yellowhammer can\u{2019}t read this Project\u{2019}s Journal.",
                systemImage: "exclamationmark.triangle"
            )
            Text(failure)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .accessibilityIdentifier("pulse-journal-failure")
    }
}
