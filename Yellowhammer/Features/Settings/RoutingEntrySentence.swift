import Config
import SwiftUI

/// One Card entry as a sentence, the way Mail's rules read: "Cards of [impl] in [backend] repos go to
/// claude opus high; if that fails, …". Every blank is a control. While "Test a Card" is open, the entry
/// that answers it is lit through `standing`.
struct RoutingEntrySentence: View {
    @Binding var entry: RoutingEntryDraft
    /// The whole table, whose Kinds and models the controls offer.
    let table: [RoutingEntryDraft]
    var standing = TryStanding.notMatching
    /// Opens "Test a Card" on this entry's key.
    let test: () -> Void
    let duplicate: () -> Void
    let remove: () -> Void
    @Environment(\.routingCatalog) private var catalog

    var body: some View {
        SettingsCard(isHighlighted: standing == .routes) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Cards of")
                KindPopUp(value: $entry.kind, purpose: .entry, kinds: catalog.kinds(in: table))
                Text("in")
                RepoRolePicker(repoRole: $entry.repoRole)
                if !entry.isAnyRepoRole { Text("repos") }
                Spacer(minLength: 8)
                TryStandingBadge(standing: standing)
                menu
            }
            ChainSentence(chain: $entry.chain, table: table)
            if entry.isCatchAll {
                Text("The catch-all: routes every Card no other entry matches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ReplacedNote(entry: entry)
        }
    }

    private var menu: some View {
        Menu {
            Button("Test a Card for This Entry\u{2026}", systemImage: "questionmark.circle", action: test)
            Button("Duplicate", systemImage: "plus.square.on.square", action: duplicate)
            Divider()
            Button("Delete Routing Entry", systemImage: "trash", role: .destructive, action: remove)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Routing Entry actions")
    }
}

/// A Route and its fallbacks as the rest of a sentence: "go to …", "if that fails, …", "then …", and a
/// button that adds the next.
struct ChainSentence: View {
    @Binding var chain: [RouteDraft]
    let table: [RoutingEntryDraft]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("go to").foregroundStyle(.secondary)
                RouteButton(route: $chain.route(at: 0), table: table)
            }
            ForEach(chain.indices.dropFirst(), id: \.self) { index in
                HStack(spacing: 8) {
                    Text(index == 1 ? "if that fails," : "then").foregroundStyle(.secondary)
                    RouteButton(route: $chain.route(at: index), table: table)
                    RemoveRouteButton { chain.remove(at: index) }
                        .accessibilityLabel("Remove fallback \(index)")
                }
                .padding(.leading, CGFloat(min(index, 2)) * 14)
            }
            Button(chain.count == 1 ? "If that fails, try\u{2026}" : "Then try\u{2026}", systemImage: "plus") {
                if let last = chain.last { chain.append(last) }
            }
            .buttonStyle(.borderless)
            .padding(.leading, CGFloat(min(chain.count, 2)) * 14)
        }
    }
}
