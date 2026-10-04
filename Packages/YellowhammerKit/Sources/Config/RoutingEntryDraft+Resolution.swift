import Domain

// What the base Routing Table pane asks of a table still being edited, so the Operator can try it before
// saving: which entry would route a Card, and which Route would verify a Cycle. The selection rule is
// the engine's (`RouteResolver.selectEntry`), restated over drafts because the app cannot link Engine.
// Both answer from the table alone: no Probe Result, and no Project's own entries.

extension RouteDraft {
    /// Whether every part is filled in. Whether the values are valid is the loader's to say.
    public var isComplete: Bool { !cli.isEmpty && !model.isEmpty && !effort.isEmpty }
}

extension RoutingEntryDraft {
    /// The Kind the entry names — `""` and `*` are any — or nil when `kind` is not a valid Kind.
    public var parsedKind: Kind? { kind.isEmpty ? .any : Kind(kind) }

    /// The Repo Role the entry names; `""` and `*` are any.
    public var parsedRepoRole: RepoRoleMatch {
        repoRole.isEmpty || repoRole == "*" ? .any : .role(RepoRole(rawValue: repoRole))
    }

    /// The (Kind, Repo Role) key the merge and the duplicate check use; nil when `kind` is not a valid Kind.
    public var key: RoutingEntry.Key? {
        parsedKind.map { RoutingEntry.Key(kind: $0, repoRole: parsedRepoRole) }
    }

    public var isAnyKind: Bool { parsedKind == .any }
    public var isAnyRepoRole: Bool { parsedRepoRole == .any }
    /// The entry for any Kind and any Repo Role: it routes every Card no other entry matches.
    public var isCatchAll: Bool { isAnyKind && isAnyRepoRole }

    /// Whether this is the entry for the reserved authoring Kind itself, which the author Act and
    /// Verification resolve to ahead of the catch-all.
    public var isAuthoringEntry: Bool { parsedKind == .authoring }

    /// The Route then its fallbacks, as one list in the order they are tried.
    public var chain: [RouteDraft] {
        get { [route] + fallbacks }
        set {
            route = newValue.first ?? RouteDraft(cli: "", model: "", effort: "")
            fallbacks = Array(newValue.dropFirst())
        }
    }

    /// How strongly the entry claims a Card it applies to: Kind specificity first, then whether it names
    /// the Repo Role (`RouteResolver.rank`).
    fileprivate var precedence: (Int, Int) {
        (parsedKind?.specificity ?? 0, isAnyRepoRole ? 0 : 1)
    }

    /// Whether the entry applies to a Card of `kind` in a Repo of `repoRole`; a nil `repoRole` is the
    /// author Act's and Verification's, which only an any-Repo-Role entry applies to.
    fileprivate func applies(to kind: Kind, repoRole: RepoRole?) -> Bool {
        guard let parsedKind, parsedKind.isPrefix(of: kind) else { return false }
        switch parsedRepoRole {
        case .any: return true
        case .role(let role): return role == repoRole
        }
    }
}

extension [RoutingEntryDraft] {
    /// The indices of the entries that apply to a Card of `kind` in a Repo of `repoRole`, the one that
    /// routes it first: the longest Kind prefix wins, then the entry naming the Repo Role. Between two
    /// entries for the same key — a table the loader would refuse — the earlier wins, as in the engine.
    public func candidates(kind: Kind, repoRole: RepoRole?) -> [Int] {
        indices
            .filter { self[$0].applies(to: kind, repoRole: repoRole) }
            .sorted { lhs, rhs in
                let left = self[lhs].precedence, right = self[rhs].precedence
                return left == right ? lhs < rhs : left > right
            }
    }

    /// The index of the entry the author Act and Verification resolve to: the authoring entry, or else
    /// the catch-all. Nil when neither exists.
    public var authoringResolution: Int? {
        candidates(kind: .authoring, repoRole: nil).first
    }

    /// The Route Verification would run for a Cycle whose code `writers` wrote: the first Route of the
    /// entry the authoring Kind resolves to that is none of them. Nil when no entry applies, or every
    /// Route of that entry wrote the code.
    public func verifier(excluding writers: Set<RouteDraft>) -> RouteDraft? {
        guard let index = authoringResolution else { return nil }
        return self[index].chain.first { !writers.contains($0) }
    }

    /// Every distinct complete Route a worker can run a Card on — the chains of every entry but the
    /// authoring entry — in table order.
    public var workerRoutes: [RouteDraft] {
        var seen = Set<RouteDraft>()
        return filter { !$0.isAuthoringEntry }
            .flatMap(\.chain)
            .filter { $0.isComplete && seen.insert($0).inserted }
    }
}
