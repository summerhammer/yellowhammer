import Domain
import SwiftUI

/// The Settings window's sidebar, drawn like the Add Project sheet's hub: the machine-wide sections, each
/// with a line saying what it holds, then the configured Projects.
///
/// Each Project is listed by its name only: no status, badge, count or id (R20). A Project whose file
/// was refused is not in `projects`, so it is never listed here (OQ79); its file is under Refused Files.
struct SettingsSidebar: View {
    let projects: [ConfiguredProjects.Entry]
    /// Nil until the configuration has been read.
    let configured: ConfiguredProjects?
    /// The current section. The window derives it from its history and records each set as a visit.
    @Binding var selection: SettingsSection?
    /// Runs with the new Project's id after the Operator adds one from here. The window owns it.
    let onProjectAdded: @MainActor (ProjectID) -> Void
    @Environment(\.addProject) private var addProject

    var body: some View {
        List(selection: $selection) {
            Section("This Mac") {
                SettingsSidebarRow(title: "General", summary: "Orca ADE")
                    .tag(SettingsSection.general)
                    .accessibilityIdentifier("settings-general")
                SettingsSidebarRow(title: "Boards", summary: "Board connections")
                    .tag(SettingsSection.boards)
                    .accessibilityIdentifier("settings-boards")
                SettingsSidebarRow(title: "Code Hosting", summary: "GitHub connections")
                    .tag(SettingsSection.codeHosting)
                    .accessibilityIdentifier("settings-code-hosting")
                SettingsSidebarRow(title: "Agent CLIs", summary: "Declared CLIs and their Probes")
                    .tag(SettingsSection.agentCLIs)
                    .accessibilityIdentifier("settings-agent-clis")
                SettingsSidebarRow(title: "Base Routing Table", summary: "Routes every Project shares")
                    .tag(SettingsSection.baseRoutingTable)
                    .accessibilityIdentifier("settings-base-routing-table")
                SettingsSidebarRow(title: "Refused Files", summary: refusedSummary, problemCount: refusedCount)
                    .tag(SettingsSection.refusedFiles)
                    .accessibilityIdentifier("settings-refused-files")
            }
            Section("Projects") {
                ForEach(projects) { project in
                    SettingsSidebarRow(title: project.name)
                        .tag(SettingsSection.project(project.id))
                        .accessibilityIdentifier("settings-project-\(project.id.rawValue)")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, alignment: .leading) {
            Button { addProject(onAdded: onProjectAdded) } label: {
                Label("Add Project\u{2026}", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .help("Add Project")
            .accessibilityLabel("Add Project")
            .accessibilityIdentifier("settings-add-project")
            .padding(12)
        }
    }

    private var refusedCount: Int {
        configured?.refused.count ?? 0
    }

    private var refusedSummary: String {
        guard let configured else { return "" }
        if configured.loadFailure != nil { return "The configuration can\u{2019}t be read" }
        switch configured.refused.count {
        case 0: return "None"
        case 1: return "1 file"
        case let count: return "\(count) files"
        }
    }
}

/// One sidebar row: a title, an optional summary under it, and a trailing count in `error` when the
/// section holds problems — the Add Project hub's row.
private struct SettingsSidebarRow: View {
    let title: String
    var summary: String?
    var problemCount = 0

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium).lineLimit(1)
                if let summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if problemCount > 0 {
                Text("\(problemCount)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.onError)
                    .padding(.horizontal, 6)
                    .background(.error, in: .capsule)
                    .accessibilityLabel("\(problemCount) refused")
            }
        }
        .padding(.vertical, 3)
        // One element per row, so the row's identifier names the row rather than each of its texts.
        .accessibilityElement(children: .combine)
    }
}
