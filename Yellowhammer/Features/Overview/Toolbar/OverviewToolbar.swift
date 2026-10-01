import Domain
import Pulse
import SwiftUI

/// The main window's toolbar: the standard Inspector toggle, and Stop the engine for the selected
/// Project (spec: app/stop-the-engine-for-a-project). The app triggers and never decides or records:
/// confirming runs `yh stop --project <id>`, which records the request in the engine, so quitting the
/// app cannot change the outcome. Nothing is paused and nothing here polls.
struct OverviewToolbar: ToolbarContent {
    @Binding var inspectorShown: Bool
    let stop: EngineStopModel
    /// The Project the window shows: Stop always targets it, never another.
    let project: ProjectSnapshot?
    @Binding var confirming: Bool

    var body: some ToolbarContent {
        ToolbarItem {
            Button {
                inspectorShown.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the Inspector")
            .accessibilityIdentifier("toolbar-inspector-toggle")
        }
        ToolbarItem {
            Button {
                confirming = true
            } label: {
                if stop.isStopping(project?.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Stop the Engine", systemImage: "stop.circle")
                }
            }
            .disabled(!canStop)
            .help(helpText)
            .accessibilityIdentifier("toolbar-stop-engine")
        }
    }

    /// Offered only while the Project is working and at least one Attempt in it is running.
    private var canStop: Bool {
        guard let project, !stop.isStopping(project.id) else { return false }
        return project.pulse.now.status == .working && !project.pulse.now.attempts.isEmpty
    }

    private var helpText: String {
        if stop.isStopping(project?.id) { return "Stopping…" }
        guard let project else { return "Stop the engine" }
        return "Stop the engine for \(project.name): abort every running Attempt in it"
    }
}

extension View {
    /// The confirmation, and the failure alert, of Stop the engine.
    func stopTheEngineDialogs(
        confirming: Binding<Bool>, stop: EngineStopModel, project: ProjectSnapshot?,
        afterStop: @escaping () async -> Void
    ) -> some View {
        let name = project?.name ?? "this Project"
        let running = project?.pulse.now.attempts.count ?? 0
        return confirmationDialog(
            "Stop the engine for \(name)?", isPresented: confirming, titleVisibility: .visible
        ) {
            Button("Stop the Engine", role: .destructive) {
                guard let project else { return }
                Task {
                    await stop.stop(project: project.id)
                    await afterStop()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This aborts the \(running) running Attempt(s) in \(name). Each Card is Blocked with " +
                    "“operator abort” until you re-ready it in Linear: the Card is reclaimable, and no " +
                    "partial state was written as if it were complete. It pauses nothing: later Acts still " +
                    "run and may dispatch this Project's other Ready Cards. Other Projects are not affected."
            )
        }
        .alert(
            "The engine could not be stopped",
            isPresented: Binding(get: { stop.failure != nil }, set: { if !$0 { stop.failure = nil } })
        ) {
            Button("OK") { stop.failure = nil }
        } message: {
            Text(stop.failure ?? "")
        }
    }
}
