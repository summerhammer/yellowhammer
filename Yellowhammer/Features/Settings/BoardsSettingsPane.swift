import SwiftUI

/// The board integrations of the Settings window's Boards section (P18.16, L3.1): a section per board
/// vendor, each listing the workspaces Yellowhammer is connected to. Only Linear is supported today; another
/// vendor's section goes beside it. The model is owned by `SettingsWindow`, so moving to another sidebar row
/// and back neither recreates it nor kills a running install.
struct BoardsSettingsPane: View {
    let model: LinearWorkspacesModel
    var highlightedBoardConnection: String?

    var body: some View {
        SettingsPane(
            title: "Boards",
            explanation: "The boards this Mac\u{2019}s Projects are driven from, and the workspaces Yellowhammer "
                + "connects to on each."
        ) {
            LinearBoardSection(model: model, highlightedBoardConnection: highlightedBoardConnection)
        }
        .onAppear { model.refreshStatusOnFirstAppearance() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-boards-pane")
    }
}
