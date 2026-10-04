#if DEBUG
import SwiftUI

/// H · Sections: the pane split by the three jobs the table routes, each section always open.
///
/// - **Cards** — a sentence per Card entry, its Kind chosen with `kindStyle` (I's pop-up or J's path),
///   and "Test a Card…" beside the heading.
/// - **Author** — the Route the author Act runs on.
/// - **Verification** — the agents that may check a finished Cycle, in order, and who would check the
///   code each worker Route writes.
///
/// The author Act and Verification share one entry, the reserved authoring Kind: its Route is the
/// author Act's, and its fallbacks are the verifiers (and the author Act's fallbacks too). Author edits
/// the first, Verification the rest, so neither section repeats the other.
struct RoutingSectionsVariant: View {
    @Binding var rules: [RoutingRule]
    let kindStyle: KindSelectorStyle
    @State private var test = CardTest()

    var body: some View {
        ScrollViewReader { proxy in
            SettingsColumn(spacing: 22) {
                if rules.isEmpty {
                    RoutingEmptyState { rules.appendNew() }
                } else {
                    cards { rule in
                        test.shownID = rule.id
                        withAnimation { proxy.scrollTo(rule.id, anchor: .center) }
                    } openTest: { rule in
                        // The popover hangs off the button, so bring the button into view first.
                        proxy.scrollTo(CardTest.anchorID, anchor: .top)
                        test.open(for: rule)
                    }
                    Divider()
                    author
                    Divider()
                    verification
                }
            }
        }
        .onChange(of: rules) { test.shownID = nil }
    }

    private var cardRules: [RoutingRule] { rules.filter { !$0.isAuthoring } }
    private var authoringRule: RoutingRule? { rules.first { $0.kindSegments == ["authoring"] } }
    private var catchAll: RoutingRule? { rules.first { $0.isAnyKind && $0.isAnyRepoRole } }

    /// Gives the author Act and Verification an entry of their own, starting from the catch-all's Routes.
    private func addAuthoringEntry() {
        let chain = catchAll?.chain ?? [RouteValue(cli: "claude", model: "opus", effort: "high")]
        rules.append(RoutingRule(kind: "authoring", route: chain[0], fallbacks: Array(chain.dropFirst())))
    }

    // MARK: Cards

    private func cards(
        show: @escaping (RoutingRule) -> Void, openTest: @escaping (RoutingRule) -> Void
    ) -> some View {
        PaneSection(
            title: "Cards",
            summary: "Who writes each Card\u{2019}s code, chosen by the Card\u{2019}s Kind and its Repo\u{2019}s Role.",
            accessory: AnyView(TestCardButton(test: $test, rules: cardRules, kindStyle: kindStyle, show: show))
        ) {
            ForEach(cardRules) { rule in
                SentenceCard(
                    rule: $rules.rule(rule.id),
                    standing: test.standing(of: rule, in: cardRules),
                    kindStyle: kindStyle,
                    knownKinds: RoutingCatalog.knownKinds(in: rules),
                    tryIt: { openTest(rule) },
                    remove: { $rules.remove(rule.id) },
                    duplicate: { rules.duplicate(rule) }
                )
                .id(rule.id)
            }
            HStack {
                Button("Add Routing Entry", systemImage: "plus") { rules.appendNew() }
                Spacer()
                Text("Order here doesn\u{2019}t matter: the entry with the most specific Kind wins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Author

    private var author: some View {
        PaneSection(
            title: "Author",
            summary: "The author Act picks the next Feature on the board and breaks it into Cards."
        ) {
            RoutingCard {
                if let entry = authoringRule {
                    HStack(spacing: 8) {
                        Text("The author Act goes to").foregroundStyle(.secondary)
                        RouteButton(route: $rules.rule(entry.id).route)
                    }
                    Text(
                        entry.fallbacks.isEmpty
                            ? "If it fails, the author Act has nowhere else to go: add a verifier below."
                            : "If it fails, the author Act tries the verifiers below, in order."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ReplacedNote(rule: entry)
                    Button("Use the Catch-All Instead", role: .destructive) { $rules.remove(entry.id) }
                        .buttonStyle(.link)
                        .font(.caption)
                } else {
                    usesCatchAll(subject: "the author Act")
                }
            }
        }
    }

    // MARK: Verification

    private var verification: some View {
        PaneSection(
            title: "Verification",
            summary: "A finished Cycle is checked by an agent that wrote none of its code: the first Route below "
                + "that didn\u{2019}t work on the Cycle."
        ) {
            RoutingCard {
                if let entry = authoringRule {
                    verifiers($rules.rule(entry.id).chain)
                } else {
                    usesCatchAll(subject: "Verification")
                }
            }
            outcomes
        }
    }

    /// The authoring entry's chain as an ordered list of verifiers: the author Act's Route first, read
    /// only here, then the fallbacks, each editable and removable.
    private func verifiers(_ chain: Binding<[RouteValue]>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Checked by the first of these that wrote none of the Cycle\u{2019}s code:")
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ordinal(1)
                RouteLabel(route: chain.wrappedValue[0])
                Text("the author Act\u{2019}s Route \u{2014} change it under Author")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(chain.wrappedValue.indices.dropFirst(), id: \.self) { index in
                HStack(spacing: 8) {
                    ordinal(index + 1)
                    RouteButton(route: chain[index])
                    RemoveRouteButton { chain.wrappedValue.remove(at: index) }
                        .accessibilityLabel("Remove verifier \(index)")
                }
            }
            Button("Add a Verifier", systemImage: "plus", action: addVerifier)
                .buttonStyle(.borderless)
        }
    }

    private func addVerifier() {
        guard let id = authoringRule?.id else { return }
        $rules.rule(id).wrappedValue.fallbacks.append(suggestedVerifier)
    }

    private func ordinal(_ place: Int) -> some View {
        Text("\(place).").monospacedDigit().foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
    }

    /// A Route no worker runs, so it can check any Cycle; the first the declared CLIs offer.
    private var suggestedVerifier: RouteValue {
        let taken = RoutingCatalog.workerRoutes(in: rules) + (authoringRule?.chain ?? [])
        return RoutingCatalog.firstRoute(avoiding: taken)
    }

    /// For each worker Route in the table, who would check the code it writes — and a fix for any that
    /// nobody can check.
    private var outcomes: some View {
        let writers = RoutingCatalog.workerRoutes(in: rules)
        let rows = writers.map { ($0, RouteResolution.verification(in: rules, writtenBy: $0).route) }
        return SettingsBlock(
            title: "Who checks whose code",
            footer: "When several Routes worked on one Cycle, every one of them is skipped."
        ) {
            ForEach(rows.indices, id: \.self) { index in
                if index > 0 { Divider().padding(.leading, 12) }
                HStack(spacing: 8) {
                    Text("Code by").foregroundStyle(.secondary)
                    RouteLabel(route: rows[index].0, compact: true)
                    Text("is checked by").foregroundStyle(.secondary)
                    if let route = rows[index].1 {
                        RouteLabel(route: route, compact: true)
                    } else {
                        Label("nobody", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(SettingsTheme.error)
                        Spacer(minLength: 8)
                        if authoringRule != nil {
                            Button("Add a Verifier", action: addVerifier)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
        }
    }

    /// What the author Act or Verification runs on while there is no authoring entry.
    @ViewBuilder private func usesCatchAll(subject: String) -> some View {
        Text("The author Act and Verification have no Routes of their own, so both use the catch-all\u{2019}s:")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let catchAll {
            ChainLine(lead: "goes to", chain: catchAll.chain)
        } else {
            Text("There is no catch-all either: \(subject) cannot run.").foregroundStyle(SettingsTheme.error)
        }
        Button("Give the Author and Verification Their Own Routes", action: addAuthoringEntry)
    }
}

/// One of the pane's sections: a heading, what it covers, then its content. Always open — not an accordion.
struct PaneSection<Content: View>: View {
    let title: String
    let summary: String
    /// A control beside the heading, such as "Test a Card…".
    var accessory: AnyView?
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
            .id(accessory == nil ? nil : CardTest.anchorID)
            content
        }
    }
}

#endif
