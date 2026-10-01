import Domain
import SwiftUI

/// One Project's settings: its Configuration (P18.13) and its Recalibrate (P18.14).
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
                // Like the form, one view per Project, so its model and its Bounds draft are never shared.
                RecalibrateView(project: project)
                    .id(project)
            }
        }
        .accessibilityIdentifier("settings-project-pane-\(project.rawValue)")
    }
}
