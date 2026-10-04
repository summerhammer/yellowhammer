import Domain
import SwiftUI

/// One Project's settings: its Configuration (P18.13) and its Recalibrate (P18.14), under one heading with
/// the Project's name and a segmented control between the two.
///
/// The pane owns both tabs' models, so moving between the tabs keeps unsaved edits, and the window gives
/// each Project its own pane (`.id`), so two Projects never share a model or a Bounds draft.
struct ProjectSettingsPane: View {
    let project: ProjectID
    /// The Project's configured name, its heading.
    let name: String
    /// Called after the Configuration form wrote the Project's file.
    var onSaved: () -> Void = {}
    /// The label for an installation's local name, shown as the Project's Linear workspace.
    var workspaceLabel: (String) -> String = { $0 }

    @State private var configuration: ProjectConfigurationModel
    @State private var recalibrate: RecalibrateModel
    @State private var tab = ProjectSettingsTab.configuration

    init(
        project: ProjectID, name: String, onSaved: @escaping () -> Void = {},
        workspaceLabel: @escaping (String) -> String = { $0 }
    ) {
        self.project = project
        self.name = name
        self.onSaved = onSaved
        self.workspaceLabel = workspaceLabel
        _configuration = State(initialValue: ProjectConfigurationModel(project: project))
        _recalibrate = State(initialValue: RecalibrateModel(project: project))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                PaneHeading(title: name, explanation: tab.explanation)
                Picker("Section", selection: $tab) {
                    ForEach(ProjectSettingsTab.allCases, id: \.self) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("settings-project-tabs") // glossary:ignore GL001
            }
            .padding([.horizontal, .top], 20)
            switch tab {
            case .configuration:
                ProjectConfigurationView(model: configuration, onSaved: onSaved, workspaceLabel: workspaceLabel)
            case .recalibrate:
                RecalibrateView(model: recalibrate)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-project-pane-\(project.rawValue)")
    }
}

/// The two halves of a Project's settings.
enum ProjectSettingsTab: CaseIterable {
    case configuration
    case recalibrate

    var title: String {
        switch self {
        case .configuration: "Configuration"
        case .recalibrate: "Recalibrate"
        }
    }

    var explanation: String {
        switch self {
        case .configuration:
            "This Project\u{2019}s file: its name, Linear project, Repos, Bounds and Routing overrides."
        case .recalibrate:
            "How close this Night came to each Bound, a new value for any of them, and a rehearsal Night."
        }
    }
}
