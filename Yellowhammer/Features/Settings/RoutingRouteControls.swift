import Config
import SwiftUI

// The base Routing Table pane's controls for a Route. A Route is picked, not typed: the agent CLI comes
// from those declared, the effort from what that CLI's adapter accepts, and only the model — an open
// string passed to the CLI verbatim — is typed, with the models this Mac already names suggested.

// MARK: - A Route, read

/// A Route in one line: the CLI quiet, the model prominent, the effort as a small tag.
struct RouteLabel: View {
    let route: RouteDraft
    var compact = false

    var body: some View {
        if route.isComplete {
            HStack(spacing: compact ? 4 : 6) {
                Text(route.cli).foregroundStyle(.secondary)
                Text(route.model).fontWeight(.medium)
                EffortTag(effort: route.effort)
            }
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(route.cli), \(route.model), \(route.effort) effort")
        } else {
            Text("Choose a Route").foregroundStyle(.secondary)
        }
    }
}

/// An effort as a small capsule beside its model.
struct EffortTag: View {
    let effort: String

    var body: some View {
        Text(effort)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.07), in: .capsule)
    }
}

/// A chain read aloud: "goes to claude opus high then codex gpt-5-codex high".
struct ChainLine: View {
    let lead: String
    let chain: [RouteDraft]

    var body: some View {
        HStack(spacing: 6) {
            Text(lead).foregroundStyle(.secondary)
            ForEach(chain.indices, id: \.self) { index in
                if index > 0 { Text("then").foregroundStyle(.secondary) }
                RouteLabel(route: chain[index], compact: index > 0)
            }
        }
    }
}

// MARK: - A Route, edited

/// A Route as a capsule button; clicking it opens ``RouteEditor`` in a popover.
struct RouteButton: View {
    @Binding var route: RouteDraft
    /// The table the Route is in, whose models are suggested beside the catalog's.
    let table: [RoutingEntryDraft]
    @State private var isEditing = false

    var body: some View {
        Button { isEditing = true } label: {
            RouteLabel(route: route)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.background, in: .capsule)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14)))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            RouteEditor(route: $route, table: table).frame(width: 380)
        }
        .help("Edit Route")
    }
}

/// The three parts of a Route as Form rows in a popover: a CLI from those declared, discovered models, and
/// an effort from those its adapter accepts.
struct RouteEditor: View {
    @Binding var route: RouteDraft
    let table: [RoutingEntryDraft]
    @Environment(\.routingCatalog) private var catalog

    var body: some View {
        Form {
            Picker("Agent CLI", selection: cliBinding) {
                if route.cli.isEmpty { Text("Choose\u{2026}").tag("") }
                ForEach(catalog.clis) { Text($0.name).tag($0.name) }
                if !route.cli.isEmpty, catalog.cli(named: route.cli) == nil {
                    Text("\(route.cli) (not declared)").tag(route.cli)
                }
            }
            RouteModelPicker(cli: route.cli, model: $route.model)
            effort
            Text("Agent CLIs are declared in the Agent CLIs pane; each one\u{2019}s adapter decides its efforts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var effort: some View {
        if let efforts = catalog.cli(named: route.cli)?.efforts, !efforts.isEmpty {
            Picker("Effort", selection: $route.effort) {
                // An effort the adapter does not accept stays visible until the Operator picks another.
                if !efforts.contains(route.effort) {
                    Text(route.effort.isEmpty ? "Choose" : route.effort).tag(route.effort)
                }
                ForEach(efforts, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
        } else {
            LabeledContent("Effort") { Text("Choose a declared agent CLI first").foregroundStyle(.secondary) }
        }
    }

    /// Changing the CLI keeps the effort when the new CLI's adapter accepts it.
    private var cliBinding: Binding<String> {
        Binding {
            route.cli
        } set: { cli in
            guard cli != route.cli else { return }
            route.effort = catalog.effort(route.effort.isEmpty ? "medium" : route.effort, carriedTo: cli)
            route.selectCLI(cli)
        }
    }
}

/// A model choice scoped to one CLI. A stored identifier absent from discovery remains visible and untouched
/// until the Operator explicitly selects a replacement. Every refresh is a one-shot bounded CLI request.
struct RouteModelPicker: View {
    let cli: String
    @Binding var model: String
    @Environment(\.routingCatalog) private var catalog
    @Environment(\.routeModelDiscovery) private var sharedDiscovery
    @State private var localDiscovery = RouteModelDiscoveryState()
    @State private var lastTaskKey: String?

    private var discovery: RouteModelDiscoveryState { sharedDiscovery ?? localDiscovery }
    private var result: AgentModelDiscoveryResult? { discovery.result(for: cli) }
    private var isLoading: Bool { discovery.isLoading(cli: cli) }

    private var models: [AgentModel] {
        switch result {
        case .live(let models): models
        case .unsupported, .failed, .none: []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("Model", selection: $model) {
                Text("Choose a model").tag("")
                if !model.isEmpty && !models.contains(where: { $0.id == model }) {
                    Text("\(model) (unavailable or unverified)").tag(model)
                }
                ForEach(models) { choice in Text(choice.label).tag(choice.id) }
            }
            .disabled(cli.isEmpty || isLoading)
            .accessibilityIdentifier("route-model-picker")
            status
        }
        .task(id: taskKey) {
            let key = taskKey
            let changed = lastTaskKey != nil && lastTaskKey != key
            lastTaskKey = key
            if changed { await refresh() } else { await loadIfNeeded() }
        }
    }

    private var taskKey: String { "\(cli)\u{0}\(catalog.cli(named: cli)?.executable ?? "")" }

    @ViewBuilder private var status: some View {
        if isLoading {
            Label("Loading models…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            switch result {
            case .live(let models) where models.isEmpty:
                HStack {
                    statusMessage("No models are available for this CLI.")
                    refreshButton("Refresh")
                }
            case .live:
                refreshButton("Refresh models")
            case .unsupported(let message):
                HStack {
                    statusMessage(message)
                    refreshButton("Retry")
                }
            case .failed(let message):
                HStack {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    refreshButton("Retry")
                }
            case .none:
                HStack {
                    statusMessage(cli.isEmpty ? "Choose a CLI first." : "Model choices have not loaded.")
                    if !cli.isEmpty { refreshButton("Retry") }
                }
            }
        }
    }

    private func statusMessage(_ message: String) -> some View {
        Text(message).font(.caption).foregroundStyle(.secondary)
    }

    private func refreshButton(_ title: String) -> some View {
        Button(title) { Task { await refresh() } }
            .font(.caption).buttonStyle(.link).disabled(isLoading)
    }

    @MainActor private func loadIfNeeded() async {
        guard !cli.isEmpty else { return }
        guard let declaration = catalog.cli(named: cli) else {
            await discovery.refresh(cli: cli, executable: nil)
            return
        }
        await discovery.loadIfNeeded(cli: cli, executable: declaration.executable)
    }

    @MainActor private func refresh() async {
        await discovery.refresh(cli: cli, executable: catalog.cli(named: cli)?.executable)
    }
}

/// The quiet "−" beside a Route that can be taken out of a chain.
struct RemoveRouteButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
    }
}

// MARK: - The key

/// A Repo Role, picked from those this Mac's files name, or any.
struct RepoRolePicker: View {
    @Binding var repoRole: String
    @Environment(\.routingCatalog) private var catalog

    var body: some View {
        Picker("Repo Role", selection: $repoRole) {
            Text("Any Repo Role").tag("")
            if !catalog.repoRoles.isEmpty { Divider() }
            ForEach(catalog.repoRoles, id: \.self) { Text($0).tag($0) }
            if !repoRole.isEmpty, !catalog.repoRoles.contains(repoRole) {
                Text(repoRole).tag(repoRole)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - Notes

/// "Replaced in Yellowhammer": a Project's own entry for this key wins, so this one never routes there.
struct ReplacedNote: View {
    let entry: RoutingEntryDraft
    @Environment(\.routingCatalog) private var catalog

    var body: some View {
        let projects = catalog.projectsReplacing(entry)
        if !projects.isEmpty {
            Label(
                "Replaced in \(projects.formatted(.list(type: .and))) by its own entry",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.info)
        }
    }
}

extension Binding where Value == [RouteDraft] {
    /// The Route at `index`, read and written only while it exists, so a popover still open on a removed
    /// fallback never writes past the end of the chain.
    func route(at index: Int) -> Binding<RouteDraft> {
        Binding<RouteDraft> {
            wrappedValue.indices.contains(index) ? wrappedValue[index] : RouteDraft(cli: "", model: "", effort: "")
        } set: { newValue in
            if wrappedValue.indices.contains(index) { wrappedValue[index] = newValue }
        }
    }
}
