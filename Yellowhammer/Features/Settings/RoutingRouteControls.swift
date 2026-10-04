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

/// The three parts of a Route as Form rows in a popover: a CLI from those declared, a model with the
/// ones this Mac names for that CLI suggested, and an effort from those its adapter accepts.
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
            TextField("Model", text: $route.model, prompt: Text(modelPrompt))
                .textInputSuggestions(models, id: \.self) { Text($0).textInputCompletion($0) }
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

    private var models: [String] { catalog.models(for: route.cli, in: table) }
    private var modelPrompt: String { models.first.map { "e.g. \($0)" } ?? "model" }

    /// Changing the CLI keeps the effort when the new CLI's adapter accepts it.
    private var cliBinding: Binding<String> {
        Binding {
            route.cli
        } set: { cli in
            route.effort = catalog.effort(route.effort.isEmpty ? "medium" : route.effort, carriedTo: cli)
            route.cli = cli
        }
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
