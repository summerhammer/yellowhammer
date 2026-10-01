import SwiftUI

/// The machine-wide settings. A placeholder until the steps after P18.12 move them here; until then,
/// the windows that hold them stay reachable from this pane.
struct GeneralSettingsPane: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentUnavailableView {
            Label("General", systemImage: "gearshape")
        } description: {
            Text(
                "The machine-wide settings (Linear authorization, the Operator\u{2019}s identity, Agent CLIs "
                    + "and routing defaults, Orca ADE) move here in later steps. "
                    + "Until then they are in their own windows."
            )
        } actions: {
            Button("Agent CLIs\u{2026}") { openWindow(id: AgentCLIMenuCommand.windowID) }
                .accessibilityIdentifier("settings-open-agent-clis")
            Button("Base Routing Table\u{2026}") { openWindow(id: BaseRoutingTableMenuCommand.windowID) }
                .accessibilityIdentifier("settings-open-base-routing-table")
        }
        .accessibilityIdentifier("settings-general-pane")
    }
}
