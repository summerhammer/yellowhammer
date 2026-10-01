import Domain
import SwiftUI

/// One Project's settings: its Configuration and its Recalibrate. Configuration is the form (P18.13).
/// Recalibrate is a placeholder until P18.14 moves it here; until then it is in the Project's Project
/// Window.
struct ProjectSettingsPane: View {
    let project: ProjectID
    /// Called after the Configuration form wrote the Project's file.
    var onSaved: () -> Void = {}

    var body: some View {
        TabView {
            Tab("Configuration", systemImage: "slider.horizontal.3") {
                // The form's model is made once per view, so a different Project is a different view.
                ProjectConfigurationView(project: project, onSaved: onSaved)
                    .id(project)
            }
            Tab("Recalibrate", systemImage: "arrow.triangle.2.circlepath") {
                RecalibratePlaceholder(project: project)
            }
        }
        .accessibilityIdentifier("settings-project-pane-\(project.rawValue)")
    }
}

private struct RecalibratePlaceholder: View {
    let project: ProjectID
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentUnavailableView {
            Label("Recalibrate", systemImage: "wrench.and.screwdriver")
        } description: {
            Text("This is still in the Project\u{2019}s Project Window.")
        } actions: {
            Button("Open Project Window") { openWindow(id: ProjectWindow.windowID, value: project) }
                .accessibilityIdentifier("settings-open-project-window")
        }
    }
}
