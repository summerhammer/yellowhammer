import AppKit
import Domain
import SwiftUI

/// One window of the app, scoped to exactly one Project (OQ52 Face 2).
///
/// `project` is the window's own value: nil for a new window, which then shows the first configured
/// Project until the Operator picks one. The app's screens hang off this window; there is no view
/// above it and none that spans Projects.
struct ProjectWindow: View {
    @Binding var project: ProjectID?
    @State private var configured = ConfiguredProjects(entries: [], loadFailure: nil)
    @Environment(\.openWindow) private var openWindow

    /// The Project this window shows: its own value, or the first configured one for a new window.
    private var scopedProject: ProjectID? {
        project ?? configured.entries.first?.id
    }

    var body: some View {
        content
            .frame(minWidth: 560, minHeight: 480)
            .navigationTitle(configured.entry(for: scopedProject)?.name ?? "Yellowhammer")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    ProjectSelector(
                        entries: configured.entries,
                        selection: Binding(get: { scopedProject }, set: { project = $0 })
                    )
                }
            }
            .onAppear { configured = ConfiguredProjects.load() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                configured = ConfiguredProjects.load()
            }
            // Every window may take a deep link, so a link never opens a stray window of its own.
            .handlesExternalEvents(preferring: [ProjectDeepLink.scheme], allowing: [ProjectDeepLink.scheme])
            .onOpenURL(perform: open)
    }

    @ViewBuilder private var content: some View {
        if let entry = configured.entry(for: scopedProject) {
            ProjectDetailView(project: entry.id)
                .id(entry.id)
        } else {
            fallbackContent
        }
    }

    @ViewBuilder private var fallbackContent: some View {
        VStack(spacing: 8) {
            if let project {
                Text("No configured Project has the id \u{201C}\(project.rawValue)\u{201D}.")
            } else if let failure = configured.loadFailure {
                Text("Yellowhammer can\u{2019}t read its configuration.")
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                setupButton
            } else {
                Text("No Project is configured.")
                setupButton
            }
        }
        .multilineTextAlignment(.center)
        .padding()
    }

    private var setupButton: some View {
        Button("Set Up Yellowhammer…") { openWindow(id: "setup") } // glossary:ignore GL001
            .accessibilityIdentifier("open-setup")
    }

    /// Scopes a new window to the linked Project, and otherwise brings forward that Project's window,
    /// opening one if none shows it.
    private func open(_ url: URL) {
        guard let link = ProjectDeepLink(url: url) else { return }
        if project == nil || project == link.project {
            project = link.project
        } else {
            openWindow(value: link.project)
        }
    }
}
