import Domain
import Pulse
import SwiftUI

/// The main window's Sidebar: every configured Project, in configured order. Selecting a Project scopes
/// the Pulse to it. A Project whose configuration was refused is not in `projects`, so it never appears
/// here (OQ79).
struct OverviewSidebar: View {
    let projects: [ProjectSnapshot]
    @Binding var selection: ProjectID?

    var body: some View {
        List(selection: $selection) {
            Section("Projects") {
                ForEach(projects) { snapshot in
                    Text(snapshot.name)
                        .lineLimit(1)
                        .accessibilityIdentifier("sidebar-\(snapshot.id.rawValue)")
                }
            }
        }
        .listStyle(.sidebar)
    }
}
