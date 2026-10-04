import Config
import SwiftUI

/// One of the pane's sections: a heading, what it covers, then its content. Always open — not an accordion.
struct RoutingPaneSection<Accessory: View, Content: View>: View {
    let title: String
    let summary: String
    /// The scroll id of the heading, when something scrolls to it.
    var accessoryID: String?
    /// A control beside the heading, such as "Test a Card…".
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                accessory
            }
            .id(accessoryID)
            content
        }
    }
}

extension RoutingPaneSection where Accessory == EmptyView {
    init(title: String, summary: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, summary: summary, accessory: { EmptyView() }, content: content)
    }
}

/// What the pane shows while the table has no entry: what that means, and the one way forward.
struct RoutingEmptyState: View {
    let add: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Routing Entries", systemImage: "arrow.triangle.branch")
        } description: {
            Text("No Card can be dispatched until an entry routes it. Start with one for Any Kind and Any Repo Role.")
        } actions: {
            Button("Add a Catch-All Entry", action: add)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("routing-table-add-catch-all")
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

extension [RoutingEntryDraft] {
    /// A new entry for any Kind and any Repo Role, with the catch-all's Route when there is one.
    mutating func appendEntry(catalog: RoutingCatalog) {
        append(RoutingEntryDraft(route: first(where: \.isCatchAll)?.route ?? catalog.route(avoiding: [])))
    }
}

extension Binding where Value == [RoutingEntryDraft] {
    /// The entry at `index`, read and written only while it exists, so a control still on screen for a
    /// removed entry never writes past the end of the table.
    func entry(at index: Int) -> Binding<RoutingEntryDraft> {
        Binding<RoutingEntryDraft> {
            wrappedValue.indices.contains(index)
                ? wrappedValue[index] : RoutingEntryDraft(route: RouteDraft(cli: "", model: "", effort: ""))
        } set: { newValue in
            if wrappedValue.indices.contains(index) { wrappedValue[index] = newValue }
        }
    }
}
