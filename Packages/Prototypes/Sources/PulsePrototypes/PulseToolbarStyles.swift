#if DEBUG
import Domain
import Pulse
import SwiftUI

// What the window toolbar carries. Every item opens something or shows status — none is a triage
// gesture, none schedules, and none starts an Act: the toolbar may trigger and display, never decide.

enum PulseToolbarStyle: String, CaseIterable {
    /// The Inspector toggle alone; every way out lives in the Pulse.
    case minimal
    /// Night Card, the Feature in Linear, and Settings, grouped, then the Inspector toggle.
    case waysOut
    /// The Now line as a centred status item, a Journal re-read, and the Inspector toggle.
    case status
    /// A filter field over Cards and Attempts, the Night Card, and the Inspector toggle.
    case search
    /// The Project's name and read time as the window title, one Open menu, and the Inspector toggle.
    case titled
}

/// The inputs every toolbar style draws on.
struct PulseToolbarModel {
    let project: ProjectSnapshot?
    let asOf: Date
    let inspectorShown: Binding<Bool>
    let actions: PulseActions
    let prototypeAction: @MainActor (String) -> Void
    let palette: PulsePalette
}

extension View {
    /// Applies one toolbar style. Each style is its own `ToolbarContent`, so a variant's toolbar is
    /// read in one place.
    @ViewBuilder
    func pulseToolbar(_ style: PulseToolbarStyle, _ model: PulseToolbarModel) -> some View {
        switch style {
        case .minimal: toolbar { PulseMinimalToolbar(model: model) }
        case .waysOut: toolbar { PulseWaysOutToolbar(model: model) }
        case .status: toolbar { PulseStatusToolbar(model: model) }
        case .search: toolbar { PulseSearchToolbar(model: model) }
        case .titled:
            toolbar { PulseTitledToolbar(model: model) }
                .navigationSubtitle("Journal read at \(PulseFormat.time(model.asOf))")
        }
    }
}

// MARK: - Items

private struct PulseInspectorToggle: ToolbarContent {
    let model: PulseToolbarModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation { model.inspectorShown.wrappedValue.toggle() }
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help(model.inspectorShown.wrappedValue ? "Hide the Inspector" : "Show the Inspector")
        }
    }
}

private struct PulseNightCardButton: View {
    let model: PulseToolbarModel

    var body: some View {
        let link = model.project?.pulse.night?.nightCard
        Button {
            if let link { model.actions.open(.nightCard(link.url)) }
        } label: {
            Label("Night Card", systemImage: "moon.stars")
        }
        .help(link.map { "Open \($0.identifier) in Linear" } ?? "No Night Card link recorded")
        .disabled(link == nil)
    }
}

private struct PulseFeatureButton: View {
    let model: PulseToolbarModel

    private static func absence(of feature: FeatureInFlight?) -> String {
        feature == nil ? "No Feature in flight" : "No Feature link recorded"
    }

    var body: some View {
        let feature = model.project?.pulse.feature
        let link = feature?.link
        Button {
            if let link { model.actions.open(.linearIssue(link.url)) }
        } label: {
            Label("Feature in Linear", systemImage: "flag")
        }
        .help(link.map { "Open \($0.identifier) in Linear" } ?? Self.absence(of: feature))
        .disabled(link == nil)
    }
}

private struct PulseSettingsButton: View {
    let model: PulseToolbarModel

    var body: some View {
        Button { model.actions.open(.settings) } label: {
            Label("Project Settings", systemImage: "gearshape")
        }
        .help("Open this Project's Settings")
    }
}

// MARK: - Styles

private struct PulseMinimalToolbar: ToolbarContent {
    let model: PulseToolbarModel

    var body: some ToolbarContent {
        PulseInspectorToggle(model: model)
    }
}

private struct PulseWaysOutToolbar: ToolbarContent {
    let model: PulseToolbarModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            PulseNightCardButton(model: model)
            PulseFeatureButton(model: model)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) { PulseSettingsButton(model: model) }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        PulseInspectorToggle(model: model)
    }
}

private struct PulseStatusToolbar: ToolbarContent {
    let model: PulseToolbarModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if let project = model.project {
                HStack(spacing: 6) {
                    PulseStatusDot(color: model.palette.color(for: project.status))
                    Text(PulseFormat.nowLine(project.pulse.now)).lineLimit(1)
                    if !project.pulse.now.attempts.isEmpty {
                        Text("· \(project.pulse.now.attempts.count) running").foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 10)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.prototypeAction("re-read the Journal")
            } label: {
                Label("Re-read Journal", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .help("Read this Project's Journal again (as of \(PulseFormat.time(model.asOf)))")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        PulseInspectorToggle(model: model)
    }
}

private struct PulseSearchToolbar: ToolbarContent {
    let model: PulseToolbarModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { PulseNightCardButton(model: model) }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        PulseInspectorToggle(model: model)
    }
}

private struct PulseTitledToolbar: ToolbarContent {
    let model: PulseToolbarModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                PulseNightCardButton(model: model)
                PulseFeatureButton(model: model)
                Divider()
                PulseSettingsButton(model: model)
            } label: {
                Label("Open", systemImage: "arrow.up.forward.square")
            }
            .help("Open this Project's Night Card, Feature or Settings")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        PulseInspectorToggle(model: model)
    }
}
#endif
