import SwiftUI

/// The Code Hosting Connections of the Settings window's Code Hosting section: a group per Code Hosting
/// service, each listing the connections Yellowhammer pushes with. Only GitHub is supported today. The app
/// never calls GitHub, reads the Keychain or runs `gh`: every action is a `yh` invocation. The model is
/// owned by `SettingsWindow`, so moving to another sidebar row and back neither recreates it nor kills a
/// running action.
struct CodeHostingSettingsPane: View {
    let model: CodeHostingConnectionsModel

    var body: some View {
        SettingsPane(
            title: "Code Hosting",
            explanation: "The Code Hosting Connections this Mac\u{2019}s Projects push with. Each Project selects one."
        ) {
            GitHubCodeHostingSection(model: model)
            CodeHostingUnsupportedGroup()
        }
        .onAppear { model.requestRefresh() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-code-hosting-pane")
    }
}
