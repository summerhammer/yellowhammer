import Pulse
import SwiftUI

/// The main area: the selected Project's Pulse, under that Project's name, with the groups in the ruled
/// order Needs you → Now → Feature → Tonight / last Night → Health.
///
/// It takes one Project's snapshot and gives each group only that group's part of it. A group reports
/// each way out through `openPulseDestination`, and never opens anything itself.
struct PulseView: View {
    let project: ProjectSnapshot
    /// The instant the snapshot describes. Elapsed times are measured to this, not to the clock.
    let asOf: Date

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(project.name)
                    .font(.largeTitle.bold())
                    .accessibilityIdentifier("pulse-heading")
                if let failure = project.journalFailure {
                    JournalFailureNotice(failure: failure)
                } else {
                    NeedsYouGroup(needsYou: project.pulse.needsYou)
                    NowGroup(now: project.pulse.now, asOf: asOf)
                    FeatureGroup(feature: project.pulse.feature)
                    NightGroup(night: project.pulse.night)
                    HealthGroup(health: project.pulse.health)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
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
