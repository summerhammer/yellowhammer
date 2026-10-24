import Domain
import Pulse
import SwiftUI

/// The Inspector's pane for a Night whose window is open before the Journal has recorded it. It states the
/// window and that nothing is recorded yet, and invents neither a verdict nor counts. Read from the schedule
/// alone, so there is no way out: the Night Card does not exist until the Night is recorded.
struct PendingNightDetailView: View {
    let scheduled: ScheduledNight

    var body: some View {
        InspectorPane(
            kind: "Night",
            systemImage: "moon.zzz",
            style: .neutral,
            title: "Night pending",
            titleIdentifier: "pending-night-title",
            wayOut: nil,
            note: nil,
            identifier: "pending-night-detail"
        ) {
            PulseCountBadge(text: "window open", style: .neutral)
        } content: {
            Section("Window") {
                InspectorFact(label: "Opened", value: scheduled.startsAt.formatted(date: .omitted, time: .shortened))
                InspectorFact(label: "Closes", value: scheduled.endsAt.formatted(date: .omitted, time: .shortened))
            }
            Section("Recorded so far") {
                Label("Nothing yet. The Night\u{2019}s account appears once the engine records the Night.",
                      systemImage: "tray")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("pending-night-empty")
            }
        }
    }
}
