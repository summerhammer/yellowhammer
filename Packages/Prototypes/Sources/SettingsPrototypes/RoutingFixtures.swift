#if DEBUG
import Foundation

// The base Routing Table as the prototypes edit it: plain values, mirroring `RoutingEntryDraft` and
// `RouteDraft` in `Config`, which this package does not link. Every field is the string `config.toml`
// holds; `""` is "not set" for a Kind or Repo Role, which the loader reads as any.

/// The triple `(cli, model, effort)`.
struct RouteValue: Hashable {
    var cli: String
    var model: String
    var effort: String

    static let blank = RouteValue(cli: "", model: "", effort: "")

    var isComplete: Bool { !cli.isEmpty && !model.isEmpty && !effort.isEmpty }

    /// The `cli/model/effort` shorthand `config.toml` writes.
    var shorthand: String { [cli, model, effort].map { $0.isEmpty ? "?" : $0 }.joined(separator: "/") }
}

/// One `[[routing]]` entry: its key, its Route and its fallbacks in the order they are tried.
struct RoutingRule: Identifiable, Hashable {
    let id = UUID()
    var kind: String
    var repoRole: String
    var route: RouteValue
    var fallbacks: [RouteValue]

    init(kind: String = "", repoRole: String = "", route: RouteValue, fallbacks: [RouteValue] = []) {
        self.kind = kind
        self.repoRole = repoRole
        self.route = route
        self.fallbacks = fallbacks
    }

    /// The Route then its fallbacks, as one list in the order they are tried.
    var chain: [RouteValue] {
        get { [route] + fallbacks }
        set {
            route = newValue.first ?? .blank
            fallbacks = Array(newValue.dropFirst())
        }
    }

    var kindSegments: [String] {
        kind.isEmpty || kind == "*" ? [] : kind.split(separator: ".").map(String.init)
    }

    var isAnyKind: Bool { kindSegments.isEmpty }
    var isAnyRepoRole: Bool { repoRole.isEmpty }

    /// The reserved Kind the author Act and Verification resolve through; keyed with no Repo Role.
    var isAuthoring: Bool { kindSegments.first == "authoring" }

    /// The (Kind, Repo Role) key the merge and the duplicate check use.
    var key: String { "\(kindSegments.joined(separator: "."))|\(repoRole)" }

    /// Kind specificity first, then whether the entry names the Repo Role: the engine's `RouteResolver.rank`.
    var rank: (Int, Int) { (kindSegments.count, isAnyRepoRole ? 0 : 1) }

    var kindTitle: String { isAnyKind ? "Any Kind" : kindSegments.joined(separator: ".") }
    var repoRoleTitle: String { isAnyRepoRole ? "Any Repo Role" : repoRole }
    /// "impl · backend", "Any Kind · Any Repo Role".
    var title: String { "\(kindTitle) · \(repoRoleTitle)" }
}

/// A declared Agent CLI and what its adapter accepts. Efforts are the adapters' own `supportedEfforts`;
/// models are suggestions only — `model` is an open string passed to the CLI verbatim.
struct AgentCLIFixture: Identifiable, Hashable {
    let name: String
    let efforts: [String]
    let models: [String]

    var id: String { name }
}

/// What the Settings window knows besides the table: declared CLIs, the Repo Roles the Projects on this
/// Mac declare, Kinds worth suggesting, and which base entries a Project replaces with its own.
enum RoutingCatalog {
    static let clis = [
        AgentCLIFixture(name: "claude", efforts: ["low", "medium", "high", "xhigh", "max"],
                        models: ["opus", "sonnet", "haiku"]),
        AgentCLIFixture(name: "codex", efforts: ["minimal", "low", "medium", "high", "xhigh"],
                        models: ["gpt-5-codex", "gpt-5", "gpt-5-mini"])
    ]

    static func cli(named name: String) -> AgentCLIFixture? { clis.first { $0.name == name } }

    /// Every Repo Role a Project on this Mac declares.
    static let repoRoles = ["spec", "backend", "web", "mobile"]

    /// Suggestions only: a Kind is any dotted path, matched by longest prefix.
    static let kinds = ["impl", "impl.boilerplate", "impl.feature", "arch", "test", "docs", "authoring"]

    /// Base entries a Project's own table replaces outright, by key.
    static let replacedIn: [String: [String]] = ["impl|backend": ["Yellowhammer"]]

    static func projectsReplacing(_ rule: RoutingRule) -> [String] { replacedIn[rule.key] ?? [] }

    /// Every Kind worth offering: the suggestions plus every Kind the table names, parents first.
    static func knownKinds(in rules: [RoutingRule]) -> [String] {
        (kinds + rules.map { $0.kindSegments.joined(separator: ".") }).filter { !$0.isEmpty }.uniqued().sorted()
    }

    /// Every distinct Route a worker can run on a Card: the chains of every entry but authoring's.
    static func workerRoutes(in rules: [RoutingRule]) -> [RouteValue] {
        rules.filter { !$0.isAuthoring }.flatMap(\.chain).filter(\.isComplete).uniqued()
    }

    /// The first Route the declared CLIs offer that is none of `taken`, at `high` effort where the CLI
    /// accepts it.
    static func firstRoute(avoiding taken: [RouteValue]) -> RouteValue {
        let offered = clis.flatMap { cli in
            cli.models.map { RouteValue(cli: cli.name, model: $0, effort: effort("high", carriedTo: cli.name)) }
        }
        return offered.first { !taken.contains($0) } ?? offered[0]
    }

    /// The effort to keep when the CLI changes: the same one if the new CLI accepts it, else `medium`, else its first.
    static func effort(_ effort: String, carriedTo cli: String) -> String {
        guard let adapter = self.cli(named: cli) else { return effort }
        if adapter.efforts.contains(effort) { return effort }
        return adapter.efforts.contains("medium") ? "medium" : adapter.efforts.first ?? effort
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

/// Which entry routes a Card, by the engine's rule: of the entries whose Kind is a prefix of the
/// Card's and whose Repo Role is any or the Card's, the most specific Kind wins, then the one naming the
/// Repo Role.
enum RouteResolution {
    static func entry(in rules: [RoutingRule], kind: String, repoRole: String) -> RoutingRule? {
        candidates(in: rules, kind: kind, repoRole: repoRole).first
    }

    /// What Verification runs for a Cycle whose code `writtenBy` wrote: the first Route of the entry
    /// authoring resolves to — primary or fallback — that is not `writtenBy`. A nil `route` with an entry
    /// means every Route of that entry wrote the code, so the Cycle can never be verified.
    static func verification(
        in rules: [RoutingRule], writtenBy: RouteValue
    ) -> (entry: RoutingRule?, route: RouteValue?) {
        guard let entry = entry(in: rules, kind: "authoring", repoRole: "") else { return (nil, nil) }
        return (entry, entry.chain.first { $0 != writtenBy })
    }

    /// Every entry that applies, most specific first.
    static func candidates(in rules: [RoutingRule], kind: String, repoRole: String) -> [RoutingRule] {
        let segments = kind.split(separator: ".").map(String.init)
        return rules
            .filter { segments.starts(with: $0.kindSegments) && ($0.isAnyRepoRole || $0.repoRole == repoRole) }
            .sorted { $0.rank > $1.rank }
    }
}

/// The tables the Playground opens on.
enum RoutingScenario: String, CaseIterable, Identifiable {
    case typical = "A full table"
    case starter = "One catch-all entry"
    case empty = "No entries"

    var id: String { rawValue }

    var rules: [RoutingRule] {
        switch self {
        case .typical:
            [
                RoutingRule(
                    route: RouteValue(cli: "claude", model: "sonnet", effort: "medium"),
                    fallbacks: [RouteValue(cli: "codex", model: "gpt-5-codex", effort: "medium")]
                ),
                RoutingRule(
                    kind: "authoring",
                    route: RouteValue(cli: "claude", model: "opus", effort: "high"),
                    fallbacks: [RouteValue(cli: "codex", model: "gpt-5", effort: "high")]
                ),
                RoutingRule(
                    kind: "impl", repoRole: "backend",
                    route: RouteValue(cli: "claude", model: "opus", effort: "high"),
                    fallbacks: [
                        RouteValue(cli: "codex", model: "gpt-5-codex", effort: "high"),
                        RouteValue(cli: "claude", model: "sonnet", effort: "high")
                    ]
                ),
                RoutingRule(
                    kind: "impl", repoRole: "mobile",
                    route: RouteValue(cli: "codex", model: "gpt-5-codex", effort: "medium")
                ),
                RoutingRule(
                    kind: "impl.boilerplate",
                    route: RouteValue(cli: "claude", model: "haiku", effort: "low"),
                    fallbacks: [RouteValue(cli: "codex", model: "gpt-5-mini", effort: "low")]
                ),
                RoutingRule(kind: "arch", route: RouteValue(cli: "claude", model: "opus", effort: "max"))
            ]
        case .starter:
            [RoutingRule(route: RouteValue(cli: "claude", model: "sonnet", effort: "medium"))]
        case .empty:
            []
        }
    }
}
#endif
