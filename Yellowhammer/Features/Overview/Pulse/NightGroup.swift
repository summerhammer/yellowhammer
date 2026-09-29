import Pulse
import SwiftUI

/// The Pulse's Tonight / last Night group. This is a placeholder until P18.6 builds the group. It shows
/// the Night's state and opens the Night Card.
struct NightGroup: View {
    let night: NightPulse?
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                if let night {
                    Text(night.state.rawValue)
                    Button("Night Card") { openDestination(.nightCard) }
                        .buttonStyle(.link)
                } else {
                    Text("No Night yet")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Tonight / last Night", systemImage: "moon.stars")
        }
    }
}
