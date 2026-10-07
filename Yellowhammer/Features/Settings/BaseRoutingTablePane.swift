import AppKit
import Config
import SwiftUI

/// The base Routing Table pane of the Settings window's General section, reached from its sidebar or from a
/// Project's "Base Routing Table…" button (P14.3, P18.15). Not Project-scoped: this is `config.toml`'s
/// `[[routing]]`, shared by every Project.
struct BaseRoutingTablePane: View {
    @State private var model = BaseRoutingTableModel()
    @State private var modelDiscovery = RouteModelDiscoveryState()

    var body: some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.reloadIfClean()
            }
    }

    @ViewBuilder private var content: some View {
        if model.routingTable != nil {
            BaseRoutingTableFormView(model: model, modelDiscovery: modelDiscovery)
        } else {
            unavailable
        }
    }

    private var unavailable: some View {
        SettingsUnavailable(message: model.loadFailure ?? "The base Routing Table could not be loaded.")
    }
}

/// The form itself, split out so it only ever runs with a non-nil table: `model.routingTable` is
/// unwrapped once here via `Binding($model.routingTable)`.
private struct BaseRoutingTableFormView: View {
    @Bindable var model: BaseRoutingTableModel
    let modelDiscovery: RouteModelDiscoveryState

    var body: some View {
        if let table = Binding($model.routingTable) {
            ScrollViewReader { proxy in
                SettingsPane(
                    title: "Base Routing Table",
                    explanation: "Who works on each Card: the agent CLI, model and effort for each Kind and Repo "
                        + "Role, with fallbacks in order. Every Project on this Mac reads this table; a "
                        + "Project\u{2019}s own entry for the same Kind and Repo Role replaces the one here."
                ) {
                    VStack(alignment: .leading, spacing: 22) {
                        if !model.executableProblems.isEmpty {
                            executableProblems
                        }
                        RoutingSections(table: table, proxy: proxy)
                    }
                } footer: {
                    SettingsSaveFooter(
                        note: "Saving rewrites \(model.file.path(percentEncoded: false)); comments and layout in "
                            + "it are not kept. Editing the file directly stays supported.",
                        failure: model.failure,
                        isDirty: model.isDirty,
                        canSave: modelDiscovery.isValid(table.wrappedValue, preserving: model.saved ?? []),
                        identifierPrefix: "routing-table",
                        onRevert: { model.revert() },
                        onSave: { model.save() }
                    )
                }
            }
            .environment(\.routingCatalog, model.catalog)
            .environment(\.routeModelDiscovery, modelDiscovery)
        } else {
            SettingsUnavailable(message: "The base Routing Table could not be loaded.")
        }
    }

    /// A route naming a CLI that cannot run never dispatches, so say so above the table (#377).
    private var executableProblems: some View {
        SettingsCard(hasProblem: true) {
            ForEach(model.executableProblems, id: \.self) { problem in
                SettingsFailureText(text: problem, identifier: "routing-table-executable-problem")
            }
            Text("Fix it under Agent CLIs: remove the CLI and declare it again with the right path.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The table split by the three jobs it routes, each section always open:
///
/// - **Cards** — a sentence per Card entry, its Kind from a pop-up, and "Test a Card…" beside the heading.
/// - **Author** — the Route the author Act runs on.
/// - **Verification** — the agents that may check a finished Cycle, in order, and who would check the
///   code each worker Route writes.
///
/// The author Act and Verification share one entry, the reserved authoring Kind's: its Route is the
/// author Act's, and its fallbacks are the verifiers (and the author Act's fallbacks too). Author edits
/// the first, Verification the rest, so neither section repeats the other. With no entry at all the pane
/// is the first-run empty state.
private struct RoutingSections: View {
    @Binding var table: [RoutingEntryDraft]
    let proxy: ScrollViewProxy
    @State private var test = CardTest()
    @Environment(\.routingCatalog) private var catalog

    var body: some View {
        Group {
            if table.isEmpty {
                RoutingEmptyState { table.appendEntry(catalog: catalog) }
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    cards
                    Divider()
                    author
                    Divider()
                    verification
                }
            }
        }
        .onChange(of: table) { test.shownIndex = nil }
    }

    private var cardIndices: [Int] { table.indices.filter { !table[$0].isAuthoringEntry } }
    private var authoringIndex: Int? { table.firstIndex(where: \.isAuthoringEntry) }
    private var catchAll: RoutingEntryDraft? { table.first(where: \.isCatchAll) }

    /// Gives the author Act and Verification an entry of their own, starting from the catch-all's Routes.
    private func addAuthoringEntry() {
        var chain = catchAll?.chain ?? [catalog.newRoute()]
        for index in chain.indices { chain[index].model = "" }
        table.append(RoutingEntryDraft(kind: "authoring", route: chain[0], fallbacks: Array(chain.dropFirst())))
    }

    // MARK: Cards

    private var cards: some View {
        RoutingPaneSection(
            title: "Cards",
            summary: "Who writes each Card\u{2019}s code, chosen by the Card\u{2019}s Kind and its Repo\u{2019}s Role.",
            accessoryID: CardTest.anchorID
        ) {
            TestCardButton(test: $test, table: table) { index in
                test.shownIndex = index
                withAnimation { proxy.scrollTo(Self.scrollID(index), anchor: .center) }
            }
        } content: {
            ForEach(cardIndices, id: \.self) { index in
                RoutingEntrySentence(
                    entry: $table.entry(at: index),
                    table: table,
                    standing: test.standing(of: index, in: table),
                    test: { openTest(on: index) },
                    duplicate: { table.append(table[index]) },
                    remove: { table.remove(at: index) }
                )
                .id(Self.scrollID(index))
            }
            HStack {
                Button("Add Routing Entry", systemImage: "plus") { table.appendEntry(catalog: catalog) }
                    .accessibilityIdentifier("routing-table-add-entry")
                Spacer()
                Text("Order here doesn\u{2019}t matter: the entry with the most specific Kind wins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func openTest(on index: Int) {
        // The popover hangs off the button, so bring the button into view first.
        proxy.scrollTo(CardTest.anchorID, anchor: .top)
        test.prime(kinds: catalog.kinds(in: table), repoRoles: catalog.repoRoles)
        test.open(for: table[index])
    }

    private static func scrollID(_ index: Int) -> String { "routing-entry-\(index)" }

    // MARK: Author

    private var author: some View {
        RoutingPaneSection(
            title: "Author",
            summary: "The author Act picks the next Feature on the board and breaks it into Cards."
        ) {
            SettingsCard {
                if let index = authoringIndex {
                    let entry = table[index]
                    HStack(spacing: 8) {
                        Text("The author Act goes to").foregroundStyle(.secondary)
                        RouteButton(route: $table.entry(at: index).route, table: table)
                    }
                    Text(
                        entry.fallbacks.isEmpty
                            ? "If it fails, the author Act has nowhere else to go: add a verifier below."
                            : "If it fails, the author Act tries the verifiers below, in order."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ReplacedNote(entry: entry)
                    Button("Use the Catch-All Instead", role: .destructive) { table.remove(at: index) }
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
        RoutingPaneSection(
            title: "Verification",
            summary: "A finished Cycle is checked by an agent that wrote none of its code: the first Route below "
                + "that didn\u{2019}t work on the Cycle."
        ) {
            SettingsCard {
                if let index = authoringIndex {
                    verifiers($table.entry(at: index).chain)
                } else {
                    usesCatchAll(subject: "Verification")
                }
            }
            outcomes
        }
    }

    /// The authoring entry's chain as an ordered list of verifiers: the author Act's Route first, read
    /// only here, then the fallbacks, each editable and removable.
    private func verifiers(_ chain: Binding<[RouteDraft]>) -> some View {
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
                    RouteButton(route: chain.route(at: index), table: table)
                    RemoveRouteButton { chain.wrappedValue.remove(at: index) }
                        .accessibilityLabel("Remove verifier \(index)")
                }
            }
            Button("Add a Verifier", systemImage: "plus", action: addVerifier)
                .buttonStyle(.borderless)
        }
    }

    private func addVerifier() {
        guard let index = authoringIndex else { return }
        table[index].fallbacks.append(catalog.newRoute())
    }

    private func ordinal(_ place: Int) -> some View {
        Text("\(place).").monospacedDigit().foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
    }

    /// For each worker Route in the table, who would check the code it writes — and a fix for any that
    /// nobody can check.
    @ViewBuilder private var outcomes: some View {
        let writers = table.workerRoutes
        if !writers.isEmpty {
            WizardBlock(
                title: "Who checks whose code",
                footer: "When several Routes worked on one Cycle, every one of them is skipped."
            ) {
                ForEach(writers.indices, id: \.self) { index in
                    if index > 0 { Divider().padding(.leading, 12) }
                    outcome(writtenBy: writers[index])
                }
            }
        }
    }

    private func outcome(writtenBy writer: RouteDraft) -> some View {
        HStack(spacing: 8) {
            Text("Code by").foregroundStyle(.secondary)
            RouteLabel(route: writer, compact: true)
            Text("is checked by").foregroundStyle(.secondary)
            if let verifier = table.verifier(excluding: [writer]) {
                RouteLabel(route: verifier, compact: true)
            } else {
                Label("nobody", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.error)
                Spacer(minLength: 8)
                if authoringIndex != nil {
                    Button("Add a Verifier", action: addVerifier)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// What the author Act or Verification runs on while there is no authoring entry.
    @ViewBuilder private func usesCatchAll(subject: String) -> some View {
        Text("The author Act and Verification have no Routes of their own, so both use the catch-all\u{2019}s:")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let catchAll {
            ChainLine(lead: "goes to", chain: catchAll.chain)
        } else {
            Text("There is no catch-all either: \(subject) cannot run.").foregroundStyle(.error)
        }
        Button("Give the Author and Verification Their Own Routes", action: addAuthoringEntry)
    }
}

// MARK: - Previews

private extension RoutingCatalog {
    /// Two declared agent CLIs and the Repo Roles and Kinds a Mac with two Projects would name.
    static let preview = RoutingCatalog(
        clis: [
            DeclaredCLI(name: "claude", efforts: ["low", "medium", "high", "xhigh", "max"]),
            DeclaredCLI(name: "codex", efforts: ["minimal", "low", "medium", "high", "xhigh"])
        ],
        repoRoles: ["backend", "mobile", "spec", "web"],
        kinds: ["arch", "impl", "impl.boilerplate"],
        replacedIn: RoutingEntryDraft(kind: "impl", repoRole: "backend", route: previewRoute("", "", ""))
            .key.map { [$0: ["Yellowhammer"]] } ?? [:]
    )
}

private func previewRoute(_ cli: String, _ model: String, _ effort: String) -> RouteDraft {
    RouteDraft(cli: cli, model: model, effort: effort)
}

private struct RoutingSectionsPreview: View {
    @State var table: [RoutingEntryDraft]

    var body: some View {
        ScrollViewReader { proxy in
            WizardColumn { RoutingSections(table: $table, proxy: proxy) }
        }
        .environment(\.routingCatalog, .preview)
        .frame(width: 770, height: 900)
    }
}

#Preview("Base Routing Table") {
    RoutingSectionsPreview(table: [
        RoutingEntryDraft(
            route: previewRoute("claude", "sonnet", "medium"),
            fallbacks: [previewRoute("codex", "gpt-5-codex", "medium")]
        ),
        RoutingEntryDraft(
            kind: "authoring", route: previewRoute("claude", "opus", "high"),
            fallbacks: [previewRoute("codex", "gpt-5-codex", "high")]
        ),
        RoutingEntryDraft(
            kind: "impl", repoRole: "backend", route: previewRoute("claude", "opus", "high"),
            fallbacks: [previewRoute("codex", "gpt-5-codex", "high")]
        ),
        RoutingEntryDraft(kind: "impl.boilerplate", route: previewRoute("claude", "haiku", "low"))
    ])
}

#Preview("First run") {
    RoutingSectionsPreview(table: [])
}
