import Config
import SwiftUI

/// A `[[routing]]` table, editable: shared by ``ProjectConfigurationView`` (a Project's own overrides) and
/// ``BaseRoutingTablePane`` (the machine-wide base Routing Table) — one Routing Entry's shape does not
/// depend on which file it lives in.
///
/// A blank Kind or Repo Role renders as "any" (``RoutingEntryDraft``'s own default): the Operator
/// leaves the field empty rather than typing `*`.
struct RoutingEntriesEditor: View {
    @Binding var entries: [RoutingEntryDraft]

    var body: some View {
        // One Form row per view: a VStack around an entry would make the grouped Form lay its fields out
        // borderless and unprompted, so an empty field could not be seen at all.
        ForEach(entries.indices, id: \.self) { index in
            entryRows(index: index)
        }
        Button("Add Routing Entry") {
            entries.append(RoutingEntryDraft(route: RouteDraft(cli: "", model: "", effort: "")))
        }
    }

    @ViewBuilder
    private func entryRows(index: Int) -> some View {
        HStack {
            Text("Routing Entry \(index + 1)").font(.headline)
            Spacer()
            Button("Remove", role: .destructive) {
                entries.remove(at: index)
            }
        }
        TextField("Kind", text: $entries[index].kind, prompt: Text("any"))
        TextField("Repo Role", text: $entries[index].repoRole, prompt: Text("any"))
        LabeledContent("Route") {
            routeFields(
                cli: $entries[index].route.cli,
                model: $entries[index].route.model,
                effort: $entries[index].route.effort
            )
        }
        ForEach(entries[index].fallbacks.indices, id: \.self) { fallbackIndex in
            LabeledContent("Fallback \(fallbackIndex + 1)") {
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
        Button("Add Fallback") {
            entries[index].fallbacks.append(RouteDraft(cli: "", model: "", effort: ""))
        }
    }

    /// A route's three parts as bordered fields, each named by its prompt and accessibility label.
    private func routeFields(cli: Binding<String>, model: Binding<String>, effort: Binding<String>) -> some View {
        HStack {
            TextField("CLI", text: cli, prompt: Text("cli"))
            TextField("Model", text: model, prompt: Text("model"))
            TextField("Effort", text: effort, prompt: Text("effort"))
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.leading)
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
    Form {
        Section("Routing Table") {
            RoutingEntriesEditor(entries: $entries)
        }
    }
    .formStyle(.grouped)
    .frame(width: 560, height: 520)
}
