import AppKit
import Domain
import SwiftUI

/// A temporary second window, scoped to exactly one Project. It carries the screens the main window does
/// not carry yet: Configuration, the Journal account and Recalibrate.
///
/// The "Project Window…" menu item opens it for the Project the main window shows. `project` is the
/// window's own value, fixed when the window opens. It is nil only when no main window was key, and the
/// window then shows the first configured Project. A deep link never opens this window: it opens the
/// main window. The window is deleted when P18.14 moves its last screen into the Settings window.
///
/// The Night Card, Feature detail, Card detail and every triage gesture are Linear's, so none of them
/// is a tab here (P14.8).
struct ProjectWindow: View {
    static let windowID = "ProjectWindow"

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
            .onAppear { configured = ConfiguredProjects.load() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                configured = ConfiguredProjects.load()
            }
    }

    @ViewBuilder private var content: some View {
        if let entry = configured.entry(for: scopedProject) {
            TabView {
                Tab("Configuration", systemImage: "gearshape") {
                    ProjectDetailView(project: entry.id)
                        .id(entry.id)
                }
                Tab("Journal", systemImage: "book") {
                    CardAccountView(project: entry.id)
                        .id(entry.id)
                }
                Tab("Recalibrate", systemImage: "slider.horizontal.3") {
                    RecalibrateView(project: entry.id)
                        .id(entry.id)
                }
            }
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
}
