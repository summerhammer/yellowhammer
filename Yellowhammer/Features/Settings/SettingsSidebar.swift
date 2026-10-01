import Domain
import SwiftUI

/// The Settings window's sidebar: the machine-wide section, then the configured Projects.
///
/// Each Project is listed by its name only: no status, badge, count or id (R20). A Project whose file
/// was refused is not in `projects`, so it is never listed here (OQ79); its file is under Refused Files.
struct SettingsSidebar: View {
    let projects: [ConfiguredProjects.Entry]
    /// The current section. The window derives it from its history and records each set as a visit.
    @Binding var selection: SettingsSection?

    var body: some View {
        List(selection: $selection) {
            Section("General") {
                Text("General")
                    .tag(SettingsSection.general)
                    .accessibilityIdentifier("settings-general")
                Text("Refused Files")
                    .tag(SettingsSection.refusedFiles)
                    .accessibilityIdentifier("settings-refused-files")
            }
            Section("Projects") {
                ForEach(projects) { project in
                    Text(project.name)
                        .lineLimit(1)
                        .tag(SettingsSection.project(project.id))
                        .accessibilityIdentifier("settings-project-\(project.id.rawValue)")
                }
            }
        }
        .listStyle(.sidebar)
    }
}
