import Pulse
import SwiftUI

/// The Pulse's Health group. This is a placeholder until P18.7 builds the group. It shows the `yh doctor`
/// flags and opens the Settings window.
struct HealthGroup: View {
    /// Nil when `yh doctor` was not read. A Journal read never fills this.
    let health: [HealthFlag]?
    @Environment(\.openPulseDestination) private var openDestination

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                switch health {
                case nil:
                    Text("yh doctor not read")
                case let flags? where flags.isEmpty:
                    Text("No flags")
                case let flags?:
                    ForEach(flags) { Text("\($0.kind.rawValue): \($0.detail)") }
                }
                Button("Open Settings") { openDestination(.settings) }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("pulse-health-settings")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Health", systemImage: "stethoscope")
        }
    }
}
