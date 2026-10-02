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
///   Project until the Operator selects one or a link scopes the window. macOS restores the value with
///   the window, so a value naming a Project that is no longer configured is dropped (`staleProject`),
///   unless a link named it.
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
    @State private var stop = EngineStopModel()
    @State private var confirmingStop = false
    @State private var abort = AttemptAbortModel()
    /// The Attempt the Operator asked to abort, while its confirmation is shown.
    @State private var abortRequest: PendingAttemptAbort?
    /// The last way out whose destination is not wired yet, stated in a notice.
    @State private var wayOut: PulseDestination?
    @Environment(\.openWindow) private var openWindow
    @Environment(SettingsRequest.self) private var settingsRequest
    @Environment(ProjectAdditions.self) private var projectAdditions
    @Environment(DeepLinkedProjects.self) private var deepLinkedProjects

    /// The Project this window shows: its own value, or the first configured one for a new window.
    private var scopedProject: ProjectID? {
        project ?? model.snapshot?.projects.first?.id
    }

    private var selectedSnapshot: ProjectSnapshot? {
        model.snapshot?.project(scopedProject)
    }

    /// The window's own value, when it names no configured Project, no refused one, and no Project a link
    /// named: restored by macOS after its Project was removed, or left by a Project removed while the
    /// window was open. Nil until the configuration has been read.
    private var staleProject: ProjectID? {
        guard let project, model.configurationFailure == nil, let snapshot = model.snapshot,
              snapshot.project(project) == nil, model.refusal(for: project) == nil,
              !deepLinkedProjects.contains(project)
        else { return nil }
        return project
    }

    var body: some View {
        NavigationSplitView {
            OverviewSidebar(
                projects: model.snapshot?.projects ?? [],
                selection: Binding(get: { scopedProject }, set: { $0.map(rescope) }),
                onProjectAdded: { id in
                    // Read again first, so the new row exists when the window scopes to it.
                    Task {
                        await model.load()
                        rescope(id)
                    }
                }
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
        .toolbar {
            OverviewToolbar(
                inspectorShown: $inspectorShown, stop: stop, project: selectedSnapshot, confirming: $confirmingStop,
                reread: model.readOnRequest
            )
        }
        .stopTheEngineDialogs(
            confirming: $confirmingStop, stop: stop, project: selectedSnapshot, afterStop: { await model.load() }
        )
        .attemptAbortDialogs(
            pending: $abortRequest, abort: abort, afterAbort: { await model.load() }
        )
        .environment(\.openPulseDestination, route)
        .environment(\.attemptAbort, attemptAbortControl)
        .focusedSceneValue(\.overviewProject, scopedProject)
        .task { await readWhileOpen() }
        // A sheet finishing fires neither appear nor didBecomeActive; the initial load is `readWhileOpen`'s.
        .onChange(of: projectAdditions.token) { Task { await model.load() } }
        .onChange(of: staleProject, initial: true) { _, stale in
            if stale != nil { unscope() }
        }
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
                PulseView(project: selected, asOf: snapshot.asOf, inspected: inspected)
            } else if let scopedProject {
                // Only a deep link keeps the window scoped to an id that is not configured: any other
                // such value is dropped (`staleProject`).
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
        if let snapshot = model.snapshot, let selected = snapshot.project(scopedProject) {
            InspectorView(project: selected, selection: inspected, asOf: snapshot.asOf)
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
        let openWindow = openWindow
        let settingsRequest = settingsRequest
        let scopedProject = scopedProject
        return { destination in
            switch destination {
            case let .inspector(selection):
                inspected.wrappedValue = selection
                inspectorShown.wrappedValue = true
            case .settings:
                // Settings opens on this window's Project, even when it is already open.
                settingsRequest.request(scopedProject)
                openWindow(id: SettingsWindow.windowID)
            case .nightCard, .pullRequest, .linearIssue:
                // Placeholder until the Night Card, Linear and GitHub ways out are wired.
                wayOut.wrappedValue = destination
            }
        }
    }

    /// Abort Attempt, offered only for an Attempt of the selected Project while that Project is working and
    /// the Attempt is among its running ones, the same gate as Stop the engine.
    private var attemptAbortControl: AttemptAbortControl {
        let abort = abort
        let selected = selectedSnapshot
        let request = $abortRequest
        return AttemptAbortControl(
            canAbort: { id, attempt in
                guard let selected, selected.id == id, selected.pulse.now.status == .working else { return false }
                return selected.pulse.now.attempts.contains { $0.id == attempt.id }
                    && !abort.isAborting(AbortTarget(project: id, attemptID: attempt.id))
            },
            isAborting: { id, attempt in abort.isAborting(AbortTarget(project: id, attemptID: attempt.id)) },
            request: { request.wrappedValue = PendingAttemptAbort(project: $0, attempt: $1) }
        )
    }

    // MARK: Reading

    /// Reads the snapshot when the window opens, then again each time the app becomes active, unless a
    /// read is still running then (`OverviewModel.readOnActivation`). The loop never waits for a read,
    /// because the notifications would queue behind it. It is the window's own task, so it ends when the
    /// window closes.
    private func readWhileOpen() async {
        await model.load()
        for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
            model.readOnActivation()
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

    /// Returns the window to unscoped, so it shows the first configured Project, or the onboarding view
    /// when there is none. Clears the selection and notice, as `rescope` does.
    private func unscope() {
        inspected = nil
        wayOut = nil
        project = nil
    }

    /// Scopes an unscoped window to the linked Project. A window that already shows a different Project
    /// keeps it, and the link brings forward that Project's window, or opens one.
    private func open(_ url: URL) {
        guard let link = ProjectDeepLink(url: url) else { return }
        deepLinkedProjects.record(link.project)
        if project == nil || project == link.project {
            rescope(link.project)
        } else {
            openWindow(id: Self.windowID, value: link.project)
        }
    }
}
