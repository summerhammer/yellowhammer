import Config
import Domain
import SwiftUI

// "Test a Card…": a tool opened on demand, never a setting. It asks which agent the table being edited
// would give an imaginary Card and answers live; nothing it asks is saved. The answer is the base table's
// alone — a Project's own entries, and Probe Results, can change it at dispatch.

/// The imaginary Card the test asks about. A Card always has a Kind and a Repo Role.
struct TryQuery: Equatable {
    var kind = ""
    var repoRole = ""

    /// The indices of the entries of `table` that apply, the one that routes the Card first.
    func candidates(in table: [RoutingEntryDraft]) -> [Int] {
        guard let kind = Kind(kind) else { return [] }
        return table.candidates(kind: kind, repoRole: repoRole.isEmpty ? nil : RepoRole(rawValue: repoRole))
    }
}

/// Where an entry stands for the Card being tested.
enum TryStanding {
    case routes, outranked, notMatching
}

/// The test's state: whether it is open, what it asks, and the entry "Show Entry" last scrolled to. An
/// entry is lit only while the test is open, or as the one just shown — never as a lasting mark.
struct CardTest {
    /// The scroll id of the heading holding the "Test a Card…" button.
    static let anchorID = "card-test"

    var isOpen = false
    var query = TryQuery()
    /// The index of the entry "Show Entry" scrolled to.
    var shownIndex: Int?

    func standing(of index: Int, in table: [RoutingEntryDraft]) -> TryStanding {
        guard isOpen else { return index == shownIndex ? .routes : .notMatching }
        guard let place = query.candidates(in: table).firstIndex(of: index) else { return .notMatching }
        return place == 0 ? .routes : .outranked
    }

    /// Opens the test on `entry`'s own key. An any Kind or any Repo Role keeps the one already asked
    /// about, since a Card always has both.
    mutating func open(for entry: RoutingEntryDraft) {
        if !entry.isAnyKind { query.kind = entry.kind }
        if !entry.isAnyRepoRole { query.repoRole = entry.repoRole }
        shownIndex = nil
        isOpen = true
    }

    /// Fills a blank question with the first Kind and Repo Role the catalog offers.
    mutating func prime(kinds: [String], repoRoles: [String]) {
        if query.kind.isEmpty { query.kind = kinds.first ?? "impl" }
        if query.repoRole.isEmpty { query.repoRole = repoRoles.first ?? "" }
    }
}

/// A button that opens ``TryPanel`` in a popover. "Show Entry" closes it and hands the entry to `show`.
struct TestCardButton: View {
    @Binding var test: CardTest
    let table: [RoutingEntryDraft]
    let show: (Int) -> Void
    @Environment(\.routingCatalog) private var catalog

    var body: some View {
        Button("Test a Card\u{2026}", systemImage: "questionmark.circle") {
            test.prime(kinds: catalog.kinds(in: table), repoRoles: catalog.repoRoles)
            test.isOpen = true
        }
        .help("Ask which agent would get a Card. Nothing is saved.")
        .accessibilityIdentifier("routing-table-test-card")
        .popover(isPresented: $test.isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Test a Card").font(.headline)
                TryPanel(query: $test.query, table: table) { index in
                    test.isOpen = false
                    show(index)
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
    let table: [RoutingEntryDraft]
    /// Brings the answering entry into view.
    let show: (Int) -> Void
    @Environment(\.routingCatalog) private var catalog

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which agent would work on a Card like this?").font(.body.weight(.medium))
            HStack(spacing: 8) {
                Text("Kind")
                KindPopUp(value: $query.kind, purpose: .question, kinds: catalog.kinds(in: table))
                Text("in a")
                if catalog.repoRoles.isEmpty {
                    TextField("Repo Role", text: $query.repoRole, prompt: Text("backend"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                } else {
                    Picker("Repo Role", selection: $query.repoRole) {
                        ForEach(catalog.repoRoles, id: \.self) { Text($0).tag($0) }
                        if !catalog.repoRoles.contains(query.repoRole) {
                            Text(query.repoRole).tag(query.repoRole)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Text("Repo")
            }
            answer
            Label(
                "A test of this table only \u{2014} nothing here is saved, and a Project\u{2019}s own entries "
                    + "can still replace the answer.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var answer: some View {
        if let index = query.candidates(in: table).first {
            let winner = table[index]
            VStack(alignment: .leading, spacing: 6) {
                ChainLine(lead: "It would go to", chain: winner.chain)
                HStack(spacing: 6) {
                    let reason = winner.isAnyKind ? "the catch-all" : "the most specific that matches"
                    Text("Decided by the entry for \(Self.title(of: winner)), \(reason).")
                        .foregroundStyle(.secondary)
                    Button("Show Entry") { show(index) }.buttonStyle(.link)
                }
                .font(.caption)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("routing-table-test-answer")
        } else {
            Label("No agent: no entry matches, so it would be Blocked.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.error)
                .accessibilityIdentifier("routing-table-test-answer")
        }
    }

    /// "impl · backend", "Any Kind · Any Repo Role".
    static func title(of entry: RoutingEntryDraft) -> String {
        "\(KindPopUp.title(of: entry.kind)) \u{00B7} \(entry.isAnyRepoRole ? "Any Repo Role" : entry.repoRole)"
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
                .foregroundStyle(.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.accent.opacity(0.12), in: .capsule)
        case .outranked:
            Text("Matches, but less specific").font(.caption).foregroundStyle(.secondary)
        case .notMatching:
            EmptyView()
        }
    }
}
