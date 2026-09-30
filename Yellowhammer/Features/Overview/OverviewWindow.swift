import AppKit
import Domain
import Pulse
import SwiftUI

/// The main window: the Sidebar, the selected Project's Pulse, and the Inspector (Landing Screen
/// Ruling, amended by its Window Layout ruling). "Overview" is a code name only. The window always shows
/// one selected Project, never a blend of several (R20).
///
/// Where each piece of state lives:
/// - **The selected Project** is the window's own value, `project`. A deep link finds the window that
///   shows a Project by this value. A new window keeps it nil (unscoped) and shows the first configured
///   Project until the Operator selects one or a link scopes the window.
/// - **The Inspector's selection** is `inspected`. It is cleared whenever the selected Project changes,
///   and the Inspector shows it only while it names something in that Project.
/// - **The snapshot** belongs to `OverviewModel`, and is read again on appear and whenever the app
///   becomes active.
///
/// Every view below this one takes plain values and reports each way out through
/// `openPulseDestination`. `route` is the one place that decides where a way out goes.
struct OverviewWindow: View {
    static let windowID = "overview"

    @Binding var project: ProjectID?
    @State private var model = OverviewModel()
    @State private var inspected: PulseSelection?
    @State private var inspectorShown = true
    /// The last way out whose destination is not wired yet, stated in a notice.
    @State private var wayOut: PulseDestination?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    /// The Project this window shows: its own value, or the first configured one for a new window.
    private var scopedProject: ProjectID? {
        project ?? model.snapshot?.projects.first?.id
    }

    private var selectedSnapshot: ProjectSnapshot? {
        model.snapshot?.project(scopedProject)
    }

    var body: some View {
        NavigationSplitView {
            OverviewSidebar(
                projects: model.snapshot?.projects ?? [],
                selection: Binding(get: { scopedProject }, set: { $0.map(rescope) })
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            // The window's minimum comes from its columns' minimums alone. A minimum frame around the
            // whole split view as well makes AppKit loop on the split view's constraints until it
            // throws, whenever the window must grow to fit (a saved frame smaller than the minimum).
            detail
                .frame(minWidth: 380, minHeight: 320)
                .safeAreaInset(edge: .bottom) {
                    if let wayOut {
                        WayOutNotice(destination: wayOut) { self.wayOut = nil }
                    }
                }
        }
        .inspector(isPresented: $inspectorShown) {
            inspector
                .inspectorColumnWidth(min: 240, ideal: 280, max: 400)
        }
        .navigationTitle(selectedSnapshot?.name ?? "Yellowhammer")
        .environment(\.openPulseDestination, route)
        .focusedSceneValue(\.overviewProject, scopedProject)
        .task { await readWhileOpen() }
        // Every main window can take a deep link, so a link never opens a stray window of its own.
        .handlesExternalEvents(preferring: [ProjectDeepLink.scheme], allowing: [ProjectDeepLink.scheme])
        .onOpenURL(perform: open)
    }

    // MARK: Columns

    @ViewBuilder private var detail: some View {
        if let failure = model.configurationFailure {
            OverviewUnavailable(reason: .configurationUnreadable(failure))
        } else if let snapshot = model.snapshot {
            if let selected = snapshot.project(scopedProject) {
                PulseView(project: selected, asOf: snapshot.asOf)
            } else if let scopedProject {
                // Only a deep link can scope the window to an id that is not configured.
                if let refusal = model.refusal(for: scopedProject) {
                    OverviewUnavailable(reason: .refusedProject(scopedProject, refusal))
                } else {
                    OverviewUnavailable(reason: .unknownProject(scopedProject))
                }
            } else {
                OverviewUnavailable(reason: .noProject)
            }
        } else {
            ProgressView()
        }
    }

    @ViewBuilder private var inspector: some View {
        if let selectedSnapshot {
            InspectorView(project: selectedSnapshot, selection: inspected)
        } else {
            ContentUnavailableView("No Project Selected", systemImage: "sidebar.trailing")
        }
    }

    // MARK: Ways out

    /// Where each way out goes. Every Pulse, Sidebar and Inspector element calls this through
    /// `openPulseDestination`. The closure captures only the bindings and actions it needs, because the
    /// environment hands it to every view below this one.
    private var route: @MainActor (PulseDestination) -> Void {
        let inspected = $inspected
        let inspectorShown = $inspectorShown
        let wayOut = $wayOut
        let openSettings = openSettings
        return { destination in
            switch destination {
            case let .inspector(selection):
                inspected.wrappedValue = selection
                inspectorShown.wrappedValue = true
            case .settings:
                openSettings()
            case .nightCard, .pullRequest, .linearIssue:
                // Placeholder until the Night Card, Linear and GitHub ways out are wired.
                wayOut.wrappedValue = destination
            }
        }
    }

    // MARK: Reading

    /// Reads the snapshot when the window opens, then again each time the app becomes active, one read
    /// after another. The loop is the window's own task, so it ends when the window closes.
    private func readWhileOpen() async {
        await model.load()
        for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
            await model.load()
        }
    }

    // MARK: Scoping

    /// Shows `id` in this window. A selection or notice from the previous Project must not stay beside
    /// the new Project's Pulse, so both are cleared when the Project changes.
    private func rescope(_ id: ProjectID) {
        if id != scopedProject {
            inspected = nil
            wayOut = nil
        }
        project = id
    }

    /// Scopes an unscoped window to the linked Project. A window that already shows a different Project
    /// keeps it, and the link brings forward that Project's window, or opens one.
    private func open(_ url: URL) {
        guard let link = ProjectDeepLink(url: url) else { return }
        if project == nil || project == link.project {
            rescope(link.project)
        } else {
            openWindow(id: Self.windowID, value: link.project)
        }
    }
}
