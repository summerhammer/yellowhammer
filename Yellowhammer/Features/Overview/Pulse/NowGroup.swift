import Pulse
import SwiftUI

/// The Pulse's Now group. This is a placeholder until P18.4 builds the group. It shows the Project's
/// status and its running Attempts, and each Attempt opens in the Inspector.
struct NowGroup: View {
    let now: Now
    let asOf: Date
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Text(now.status.rawValue)
                ForEach(now.attempts) { attempt in
                    let elapsed = elapsed(since: attempt.startedAt)
                    Button("\(attempt.cardID) \u{00B7} \(attempt.route) \u{00B7} \(elapsed)") {
                        openDestination(.inspector(.attempt(attempt.id)))
                    }
                    .buttonStyle(.link)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Now", systemImage: "clock")
        }
    }

    private func elapsed(since start: Date) -> String {
        Duration.seconds(asOf.timeIntervalSince(start)).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}
