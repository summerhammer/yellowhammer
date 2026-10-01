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
        ForEach(entries.indices, id: \.self) { index in
            entryView(index: index)
            Divider()
        }
        Button("Add Routing Entry") {
            entries.append(RoutingEntryDraft(route: RouteDraft(cli: "", model: "", effort: "")))
        }
    }

    @ViewBuilder
    private func entryView(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Kind (blank = any)", text: $entries[index].kind)
            TextField("Repo Role (blank = any)", text: $entries[index].repoRole)
            routeFields(
                label: "Route",
                cli: $entries[index].route.cli,
                model: $entries[index].route.model,
                effort: $entries[index].route.effort
            )
            ForEach(entries[index].fallbacks.indices, id: \.self) { fallbackIndex in
                HStack {
                    routeFields(
                        label: "Fallback",
                        cli: $entries[index].fallbacks[fallbackIndex].cli,
                        model: $entries[index].fallbacks[fallbackIndex].model,
                        effort: $entries[index].fallbacks[fallbackIndex].effort
                    )
                    Button {
                        entries[index].fallbacks.remove(at: fallbackIndex)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                }
            }
            Button("Add Fallback") {
                entries[index].fallbacks.append(RouteDraft(cli: "", model: "", effort: ""))
            }
            Button("Remove Routing Entry", role: .destructive) {
                entries.remove(at: index)
            }
        }
        .padding(.vertical, 4)
    }

    private func routeFields(
        label: String, cli: Binding<String>, model: Binding<String>, effort: Binding<String>
    ) -> some View {
        HStack {
            TextField("\(label) CLI", text: cli)
            TextField("Model", text: model)
            TextField("Effort", text: effort)
        }
    }
}
