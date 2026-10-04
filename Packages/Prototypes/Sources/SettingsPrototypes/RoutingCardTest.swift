#if DEBUG
import SwiftUI

// "Test a Card…": a tool opened on demand, never a setting. It asks which agent the table would give an
// imaginary Card and answers live; the pane itself holds only what is saved.

/// The imaginary Card the test asks about.
struct TryQuery {
    var kind = "impl.feature"
    var repoRole = "backend"

    func candidates(in rules: [RoutingRule]) -> [RoutingRule] {
        RouteResolution.candidates(in: rules, kind: kind, repoRole: repoRole)
    }

    func standing(of rule: RoutingRule, in rules: [RoutingRule]) -> TryStanding {
        guard let place = candidates(in: rules).firstIndex(where: { $0.id == rule.id }) else { return .notMatching }
        return place == 0 ? .routes : .outranked
    }
}

/// Where an entry stands for the Card being tested.
enum TryStanding {
    case routes, outranked, notMatching
}

/// The test's state: whether it is open, what it asks, and the entry "Show Entry" last scrolled to. An
/// entry is lit only while the test is open, or as the one just shown — never as a lasting mark.
struct CardTest {
    /// The scroll id of the row holding the "Test a Card…" button.
    static let anchorID = "card-test"

    var isOpen = false
    var query = TryQuery()
    var shownID: RoutingRule.ID?

    func standing(of rule: RoutingRule, in rules: [RoutingRule]) -> TryStanding {
        if isOpen { return query.standing(of: rule, in: rules) }
        return rule.id == shownID ? .routes : .notMatching
    }

    /// Opens the test on `rule`'s own key. An any Repo Role keeps the one already asked about, since a
    /// Card always has one.
    mutating func open(for rule: RoutingRule) {
        query.kind = rule.kindSegments.joined(separator: ".")
        if !rule.isAnyRepoRole { query.repoRole = rule.repoRole }
        shownID = nil
        isOpen = true
    }
}

/// A button that opens ``TryPanel`` in a popover. "Show Entry" closes it and hands the entry to `show`.
struct TestCardButton: View {
    @Binding var test: CardTest
    let rules: [RoutingRule]
    let kindStyle: KindSelectorStyle
    let show: (RoutingRule) -> Void

    var body: some View {
        Button("Test a Card\u{2026}", systemImage: "questionmark.circle") { test.isOpen = true }
            .help("Ask which agent would get a Card. Nothing is saved.")
            .popover(isPresented: $test.isOpen, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Test a Card").font(.headline)
                    TryPanel(query: $test.query, rules: rules, kindStyle: kindStyle) { rule in
                        test.isOpen = false
                        show(rule)
                    }
                }
                .padding(18)
                .frame(width: 560, alignment: .leading)
            }
    }
}

/// The test itself: a question about an imaginary Card and the agent the table would give it.
struct TryPanel: View {
    @Binding var query: TryQuery
    let rules: [RoutingRule]
    let kindStyle: KindSelectorStyle
    /// Brings the answering entry into view; nil hides the link.
    var show: ((RoutingRule) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which agent would work on a Card like this?").font(.body.weight(.medium))
            HStack(spacing: 8) {
                Text("Kind")
                KindSelector(
                    value: $query.kind, style: kindStyle, purpose: .question,
                    knownKinds: RoutingCatalog.knownKinds(in: rules)
                )
                Text("in a")
                Picker("Repo Role", selection: $query.repoRole) {
                    ForEach(RoutingCatalog.repoRoles, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Text("Repo")
            }
            answer
            Label("A test only \u{2014} nothing here is saved.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var answer: some View {
        if let winner = query.candidates(in: rules).first {
            VStack(alignment: .leading, spacing: 6) {
                ChainLine(lead: "It would go to", chain: winner.chain)
                HStack(spacing: 6) {
                    let reason = winner.isAnyKind ? "the catch-all" : "the most specific that matches"
                    Text("Decided by the entry for \(winner.title), \(reason).").foregroundStyle(.secondary)
                    if let show {
                        Button("Show Entry") { show(winner) }.buttonStyle(.link)
                    }
                }
                .font(.caption)
            }
        } else {
            Label("No agent: no entry matches, so it would be Blocked.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(SettingsTheme.error)
        }
    }
}

/// A chain read aloud: "goes to claude opus high then codex gpt-5-codex high".
struct ChainLine: View {
    let lead: String
    let chain: [RouteValue]

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

/// "Routes this Card" on the entry that answers, a quiet note on the ones it outranked, nothing otherwise.
struct TryStandingBadge: View {
    let standing: TryStanding

    var body: some View {
        switch standing {
        case .routes:
            Text("Routes this Card")
                .font(.caption.weight(.semibold))
                .foregroundStyle(SettingsTheme.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(SettingsTheme.accent.opacity(0.12), in: .capsule)
        case .outranked:
            Text("Matches, but less specific").font(.caption).foregroundStyle(.secondary)
        case .notMatching:
            EmptyView()
        }
    }
}

/// The test without a popover to open, once per Kind selector.
#Preview("Test a Card panel") {
    @Previewable @State var popUp = TryQuery()
    @Previewable @State var path = TryQuery(kind: "impl.boilerplate", repoRole: "web")
    let rules = RoutingScenario.typical.rules
    VStack(alignment: .leading, spacing: 30) {
        TryPanel(query: $popUp, rules: rules, kindStyle: .popUp)
        Divider()
        TryPanel(query: $path, rules: rules, kindStyle: .path)
    }
    .padding(18)
    .frame(width: 560)
}
#endif
