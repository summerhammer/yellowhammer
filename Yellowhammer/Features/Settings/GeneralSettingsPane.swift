import SwiftUI

/// The machine-wide settings that have no pane of their own yet. Agent CLIs and the base Routing Table
/// have theirs (P18.15); Linear authorization, the Operator\u{2019}s identity and Orca ADE move here in
/// P18.16.
struct GeneralSettingsPane: View {
    var body: some View {
        ContentUnavailableView {
            Label("General", systemImage: "gearshape")
        } description: {
            Text(
                "The remaining machine-wide settings (Linear authorization, the Operator\u{2019}s identity, "
                    + "Orca ADE) move here in a later step."
            )
        }
        .accessibilityIdentifier("settings-general-pane")
    }
}
