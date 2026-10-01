import Domain
import SwiftUI

/// One Project's settings: its Configuration and its Recalibrate. Both are placeholders until the
/// steps after P18.12 move them here; until then they are in the Project's Project Window.
struct ProjectSettingsPane: View {
    let project: ProjectID

    var body: some View {
        TabView {
            Tab("Configuration", systemImage: "slider.horizontal.3") {
                Placeholder(project: project, title: "Configuration")
            }
            Tab("Recalibrate", systemImage: "arrow.triangle.2.circlepath") {
                Placeholder(project: project, title: "Recalibrate")
            }
        }
        .accessibilityIdentifier("settings-project-pane-\(project.rawValue)")
    }
}

private struct Placeholder: View {
    let project: ProjectID
    let title: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "wrench.and.screwdriver")
        } description: {
            Text("This is still in the Project\u{2019}s Project Window.")
        } actions: {
            Button("Open Project Window") { openWindow(id: ProjectWindow.windowID, value: project) }
                .accessibilityIdentifier("settings-open-project-window")
        }
    }
}
