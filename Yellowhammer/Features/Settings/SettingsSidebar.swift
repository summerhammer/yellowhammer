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
    /// Runs with the new Project's id after the Operator adds one from here. The window owns it.
    let onProjectAdded: @MainActor (ProjectID) -> Void
    @Environment(\.addProject) private var addProject

    var body: some View {
        List(selection: $selection) {
            Section("General") {
                Text("General")
                    .tag(SettingsSection.general)
                    .accessibilityIdentifier("settings-general")
                Text("Agent CLIs")
                    .tag(SettingsSection.agentCLIs)
                    .accessibilityIdentifier("settings-agent-clis")
                Text("Base Routing Table")
                    .tag(SettingsSection.baseRoutingTable)
                    .accessibilityIdentifier("settings-base-routing-table")
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
        .safeAreaInset(edge: .bottom, alignment: .leading) {
            Button { addProject(onAdded: onProjectAdded) } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("Add Project")
                .accessibilityLabel("Add Project")
                .accessibilityIdentifier("settings-add-project")
                .padding(8)
        }
    }
}
