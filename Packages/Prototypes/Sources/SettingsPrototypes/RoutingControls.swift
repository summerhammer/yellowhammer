#if DEBUG
import SwiftUI

// Controls both variants share. The idea behind them: a Route is picked, not typed. The agent
// CLI comes from the declared CLIs, the effort from what that CLI's adapter accepts, and only the model —
// an open string — is typed, with the CLI's models suggested.

// MARK: - A Route, read

/// A Route in one line: the CLI quiet, the model prominent, the effort as a small tag.
struct RouteLabel: View {
    let route: RouteValue
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

// MARK: - A Route, edited

/// A Route as a button; clicking it opens ``RouteEditor`` in a popover.
struct RouteButton: View {
    @Binding var route: RouteValue
    var compact = false
    @State private var isEditing = false

    var body: some View {
        Button { isEditing = true } label: {
            RouteLabel(route: route, compact: compact)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.background, in: .capsule)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14)))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            RouteEditor(route: $route).frame(width: 380)
        }
        .help("Edit Route")
    }
}

/// The three parts of a Route as Form rows: a CLI from those declared, a model with that CLI's
/// suggested, and an effort from those its adapter accepts.
struct RouteFields: View {
    @Binding var route: RouteValue

    var body: some View {
        Picker("Agent CLI", selection: cliBinding) {
            if route.cli.isEmpty { Text("Choose\u{2026}").tag("") }
            ForEach(RoutingCatalog.clis) { Text($0.name).tag($0.name) }
            if !route.cli.isEmpty, RoutingCatalog.cli(named: route.cli) == nil {
                Text("\(route.cli) (not declared)").tag(route.cli)
            }
        }
        TextField("Model", text: $route.model, prompt: Text(modelPrompt))
            .textInputSuggestions(models, id: \.self) { Text($0).textInputCompletion($0) }
        if let adapter = RoutingCatalog.cli(named: route.cli) {
            Picker("Effort", selection: $route.effort) {
                ForEach(adapter.efforts, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
        } else {
            LabeledContent("Effort") { Text("Choose a CLI first").foregroundStyle(.secondary) }
        }
    }

    private var models: [String] { RoutingCatalog.cli(named: route.cli)?.models ?? [] }
    private var modelPrompt: String { models.first.map { "e.g. \($0)" } ?? "model" }

    /// Changing the CLI keeps the effort when the new CLI accepts it.
    private var cliBinding: Binding<String> {
        Binding {
            route.cli
        } set: { cli in
            route.effort = RoutingCatalog.effort(route.effort.isEmpty ? "medium" : route.effort, carriedTo: cli)
            route.cli = cli
        }
    }
}

/// ``RouteFields`` in a popover's Form.
struct RouteEditor: View {
    @Binding var route: RouteValue

    var body: some View {
        Form {
            RouteFields(route: $route)
            Text("CLIs are declared in the Agent CLIs pane; each one\u{2019}s adapter decides its efforts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - The key

/// A Repo Role, picked from those the Projects on this Mac declare.
struct RepoRolePicker: View {
    @Binding var repoRole: String

    var body: some View {
        Picker("Repo Role", selection: $repoRole) {
            Text("Any Repo Role").tag("")
            Divider()
            ForEach(RoutingCatalog.repoRoles, id: \.self) { Text($0).tag($0) }
            if !repoRole.isEmpty, !RoutingCatalog.repoRoles.contains(repoRole) {
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
    let rule: RoutingRule

    var body: some View {
        let projects = RoutingCatalog.projectsReplacing(rule)
        if !projects.isEmpty {
            Label(
                "Replaced in \(projects.formatted(.list(type: .and))) by its own entry",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(SettingsTheme.info)
        }
    }
}

/// What the catch-all means, in a line, or nothing.
struct KeyMeaning: View {
    let rule: RoutingRule

    var body: some View {
        if rule.isAnyKind && rule.isAnyRepoRole {
            Text("The catch-all: routes every Card no other entry matches.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

extension [RoutingRule] {
    /// A new entry with a working Route, copied from the catch-all when there is one.
    mutating func appendNew(kind: String = "", repoRole: String = "") {
        let template = first { $0.isAnyKind && $0.isAnyRepoRole }?.route
            ?? RouteValue(cli: "claude", model: "sonnet", effort: "medium")
        append(RoutingRule(kind: kind, repoRole: repoRole, route: template))
    }

    /// A copy of `rule` with the same key, Route and fallbacks, at the end of the table.
    mutating func duplicate(_ rule: RoutingRule) {
        append(RoutingRule(kind: rule.kind, repoRole: rule.repoRole, route: rule.route, fallbacks: rule.fallbacks))
    }
}

extension Binding where Value == [RoutingRule] {
    /// One entry, found by id on every read and write, so a binding outlives the entry's removal.
    func rule(_ id: UUID) -> Binding<RoutingRule> {
        Binding<RoutingRule> {
            wrappedValue.first { $0.id == id } ?? RoutingRule(route: .blank)
        } set: { newValue in
            if let index = wrappedValue.firstIndex(where: { $0.id == id }) { wrappedValue[index] = newValue }
        }
    }

    func remove(_ id: UUID) {
        wrappedValue.removeAll { $0.id == id }
    }
}
#endif
