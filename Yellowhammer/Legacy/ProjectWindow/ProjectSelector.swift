import Domain
import SwiftUI

/// The window toolbar's Project Selector: configured Project names, and nothing else — no badge,
/// roll-up word or count (OQ52 Face 2; ooux/nav-flow → Multi-Project Navigation).
///
/// It scopes the app's own screens in this window only. A status beside a name would be the start of
/// a cross-Project view, which the app may not have.
struct ProjectSelector: View {
    let entries: [ConfiguredProjects.Entry]
    @Binding var selection: ProjectID?

    var body: some View {
        Picker("Project", selection: $selection) {
            ForEach(entries) { entry in
                Text(entry.name).tag(Optional(entry.id))
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("project-selector")
    }
}
