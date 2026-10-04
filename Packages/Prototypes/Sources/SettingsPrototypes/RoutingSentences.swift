#if DEBUG
import SwiftUI

/// One Card entry as a sentence, the way Mail's rules read: "Cards of [impl] in [backend] repos go to
/// claude opus high; if that fails, …". Every blank is a control; the Kind is chosen with `kindStyle`.
/// While the "Test a Card" tool is open, the entry that answers it is lit through `standing`.
struct SentenceCard: View {
    @Binding var rule: RoutingRule
    var standing = TryStanding.notMatching
    let kindStyle: KindSelectorStyle
    /// Every Kind worth offering in the selector.
    let knownKinds: [String]
    /// Opens the "Test a Card" tool on this entry's key.
    let tryIt: () -> Void
    let remove: () -> Void
    let duplicate: () -> Void

    var body: some View {
        RoutingCard(highlighted: standing == .routes) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Cards of")
                KindSelector(value: $rule.kind, style: kindStyle, purpose: .entry, knownKinds: knownKinds)
                Text("in")
                RepoRolePicker(repoRole: $rule.repoRole)
                if !rule.isAnyRepoRole { Text("repos") }
                Spacer(minLength: 8)
                TryStandingBadge(standing: standing)
                menu
            }
            ChainSentence(chain: $rule.chain)
            KeyMeaning(rule: rule)
            ReplacedNote(rule: rule)
        }
    }

    private var menu: some View {
        Menu {
            Button("Test a Card for This Entry\u{2026}", systemImage: "questionmark.circle", action: tryIt)
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
    @Binding var chain: [RouteValue]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("go to").foregroundStyle(.secondary)
                RouteButton(route: $chain[0])
            }
            ForEach(chain.indices.dropFirst(), id: \.self) { index in
                HStack(spacing: 8) {
                    Text(index == 1 ? "if that fails," : "then").foregroundStyle(.secondary)
                    RouteButton(route: $chain[index])
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
#endif
