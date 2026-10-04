import Config
import SwiftUI

/// A `[[routing]]` table, editable: shared by ``ProjectConfigurationView`` (a Project's own overrides) and
/// ``BaseRoutingTablePane`` (the machine-wide base Routing Table) — one Routing Entry's shape does not
/// depend on which file it lives in. Each Routing Entry is a card, as the Add Project sheet draws a Repo,
/// followed by a button that adds another.
///
/// A blank Kind or Repo Role renders as "any" (``RoutingEntryDraft``'s own default): the Operator
/// leaves the field empty rather than typing `*`.
struct RoutingEntriesEditor: View {
    @Binding var entries: [RoutingEntryDraft]
    /// Shown in place of the cards while there is no Routing Entry.
    var emptyText = "No Routing Entry yet."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if entries.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.secondary)
            }
            ForEach(entries.indices, id: \.self) { index in
                entryCard(index: index)
            }
            Button("Add Routing Entry", systemImage: "plus") {
                entries.append(RoutingEntryDraft(route: RouteDraft(cli: "", model: "", effort: "")))
            }
        }
    }

    private func entryCard(index: Int) -> some View {
        SettingsCard {
            HStack {
                Text("Routing Entry \(index + 1)").font(.headline)
                Spacer()
                Button("Remove Routing Entry \(index + 1)", systemImage: "trash", role: .destructive) {
                    entries.remove(at: index)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remove")
            }
            fields(index: index)
            Button("Add Fallback", systemImage: "plus") {
                entries[index].fallbacks.append(RouteDraft(cli: "", model: "", effort: ""))
            }
            .buttonStyle(.borderless)
        }
    }

    private func fields(index: Int) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                fieldLabel("Kind")
                TextField("Kind", text: $entries[index].kind, prompt: Text("any"))
            }
            GridRow {
                fieldLabel("Repo Role")
                TextField("Repo Role", text: $entries[index].repoRole, prompt: Text("any"))
            }
            GridRow {
                fieldLabel("Route")
                HStack {
                    routeFields(
                        cli: $entries[index].route.cli,
                        model: $entries[index].route.model,
                        effort: $entries[index].route.effort
                    )
                    // Keeps the Route's fields as wide as a Fallback's, which end in a remove button.
                    Image(systemName: "minus.circle").hidden().accessibilityHidden(true)
                }
            }
            ForEach(entries[index].fallbacks.indices, id: \.self) { fallbackIndex in
                GridRow {
                    fieldLabel("Fallback \(fallbackIndex + 1)")
                    HStack {
                        routeFields(
                            cli: $entries[index].fallbacks[fallbackIndex].cli,
                            model: $entries[index].fallbacks[fallbackIndex].model,
                            effort: $entries[index].fallbacks[fallbackIndex].effort
                        )
                        Button {
                            entries[index].fallbacks.remove(at: fallbackIndex)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove Fallback \(fallbackIndex + 1)")
                    }
                }
            }
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    /// A route's three parts as bordered fields, each named by its prompt and accessibility label.
    private func routeFields(cli: Binding<String>, model: Binding<String>, effort: Binding<String>) -> some View {
        HStack {
            TextField("CLI", text: cli, prompt: Text("cli"))
            TextField("Model", text: model, prompt: Text("model"))
            TextField("Effort", text: effort, prompt: Text("effort"))
        }
    }
}

#Preview {
    @Previewable @State var entries = [
        RoutingEntryDraft(route: RouteDraft(cli: "", model: "", effort: "")),
        RoutingEntryDraft(
            route: RouteDraft(cli: "claude", model: "opus", effort: "high"),
            fallbacks: [RouteDraft(cli: "codex", model: "", effort: "")]
        )
    ]
    WizardColumn {
        WizardBlock(title: "Routing Table", boxed: false) {
            RoutingEntriesEditor(entries: $entries)
        }
    }
    .frame(width: 620, height: 560)
}
