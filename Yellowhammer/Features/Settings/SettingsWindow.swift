import SwiftUI

/// The Settings window (Cmd+,). It is a stub until P18.12 builds its General and Projects sidebar and
/// its toolbar. The steps after P18.12 move Configuration, Recalibrate and the machine-wide settings
/// into it. Until then, Cmd+, and the Pulse's Health group open this stub.
struct SettingsWindow: View {
    var body: some View {
        ContentUnavailableView {
            Label("Settings", systemImage: "gearshape")
        } description: {
            Text(
                "Not built yet. A Project\u{2019}s Configuration and Recalibrate are in its Project Window, "
                    + "and the machine-wide settings have their own windows."
            )
        }
        .frame(width: 480, height: 300)
        .accessibilityIdentifier("settings-stub")
    }
}
