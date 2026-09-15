import Config
import Domain
import Foundation
import Testing

/// The fixture matrix for Routing Table merge testing.
private func set(_ scenario: String) throws -> URL {
    try #require(Bundle.module.url(forResource: "Sets/\(scenario)", withExtension: nil, subdirectory: "Fixtures"))
}

private func projectID(_ string: String) throws -> ProjectID {
    try #require(ProjectID(rawValue: string))
}

private func route(_ cli: String, _ model: String, _ effort: String) throws -> Route {
    try #require(Route(cli: cli, model: model, effort: effort))
}

private func kind(_ string: String) throws -> Kind {
    try #require(Kind(string))
}

// MARK: - Loading the routing-merge fixture set

@Test("Loading routing-merge: override and plain Projects load; routingTables are built")
func loadRoutingMergeSet() throws {
    let configuration = try Configuration.load(directory: set("routing-merge"))

    #expect(configuration.projects.map(\.id) == [try projectID("override"), try projectID("plain")])
    #expect(configuration.invalidProjects.isEmpty)
    #expect(configuration.routingTables.count == 2)
}

@Test("routing-merge: override Project's Routing Table merges base with overrides correctly")
func overrideProjectTableMergesCorrectly() throws {
    let configuration = try Configuration.load(directory: set("routing-merge"))
    guard let table = configuration.routingTable(for: try projectID("override")) else {
        Issue.record("routingTable for 'override' is nil")
        return
    }

    // Base entries in file order, the `review` entry replaced outright (its two fallbacks are
    // gone, not kept); `impl` for `backend` survives because the override is for `web`; then the
    // overrides with no base counterpart, in file order.
    #expect(table.entries == [
        RoutingEntry(
            route: try route("claude", "sonnet", "medium"),
            fallbacks: [try route("codex", "gpt-5.4", "medium")]
        ),
        RoutingEntry(
            kind: try kind("impl.boilerplate"),
            route: try route("claude", "haiku", "low"),
            fallbacks: [try route("codex", "gpt-5.4-mini", "low")]
        ),
        RoutingEntry(kind: try kind("review"), route: try route("codex", "gpt-5.4", "high")),
        RoutingEntry(
            kind: try kind("impl"), repoRole: .role(.backend), route: try route("codex", "gpt-5.4", "medium")
        ),
        RoutingEntry(kind: try kind("impl"), repoRole: .role(.web), route: try route("claude", "sonnet", "low")),
        RoutingEntry(
            kind: try kind("arch"),
            route: try route("claude", "opus", "high"),
            fallbacks: [try route("codex", "gpt-5.4", "high")]
        )
    ])
}

@Test("routing-merge: plain Project's Routing Table is just the base table")
func plainProjectTableEqualsBaseTable() throws {
    let configuration = try Configuration.load(directory: set("routing-merge"))
    guard let table = configuration.routingTable(for: try projectID("plain")) else {
        Issue.record("routingTable for 'plain' is nil")
        return
    }

    #expect(table.entries == configuration.machine.routingTable)
}

@Test("routing-merge: routingTable(for:) returns nil for a Project not in the set")
func routingTableForUnknownProjectReturnsNil() throws {
    let configuration = try Configuration.load(directory: set("routing-merge"))
    let unknown = try projectID("unknown")
    #expect(configuration.routingTable(for: unknown) == nil)
}

// MARK: - Unit tests on RoutingTable(base:overrides:)

@Test("RoutingTable(base:overrides:) with empty overrides passes base through unchanged")
func emptyOverridesPassesThroughBase() throws {
    let base = [
        RoutingEntry(kind: .any, route: try #require(Route(cli: "c", model: "m", effort: "e"))),
        RoutingEntry(kind: try #require(Kind("impl")), route: try #require(Route(cli: "c", model: "m", effort: "e")))
    ]
    let table = RoutingTable(base: base, overrides: [])
    #expect(table.entries == base)
}

@Test("RoutingTable(base:overrides:) with empty base yields overrides in order")
func emptyBaseYieldsOverridesInOrder() throws {
    let override1 = RoutingEntry(
        kind: .any, route: try #require(Route(cli: "c1", model: "m1", effort: "e1"))
    )
    let override2 = RoutingEntry(
        kind: try #require(Kind("impl")),
        route: try #require(Route(cli: "c2", model: "m2", effort: "e2"))
    )
    let overrides = [override1, override2]
    let table = RoutingTable(base: [], overrides: overrides)
    #expect(table.entries == overrides)
}

@Test("RoutingTable(base:overrides:) replaces when Kind and RepoRole match")
func replaceWhenKeyMatches() throws {
    let base = [
        RoutingEntry(
            kind: .any,
            route: try #require(Route(cli: "base-cli", model: "base-model", effort: "base-e"))
        )
    ]
    let override = RoutingEntry(
        kind: .any,
        route: try #require(Route(cli: "override-cli", model: "override-model", effort: "override-e"))
    )
    let table = RoutingTable(base: base, overrides: [override])
    #expect(table.entries.count == 1)
    #expect(table.entries[0].route.cli == "override-cli")
}

@Test("RoutingTable(base:overrides:) does not replace when Kind matches but RepoRole differs")
func noReplaceWhenOnlyKindMatches() throws {
    let base = [
        RoutingEntry(
            kind: try #require(Kind("impl")),
            repoRole: .role(.backend),
            route: try #require(Route(cli: "base", model: "m", effort: "e"))
        )
    ]
    let override = RoutingEntry(
        kind: try #require(Kind("impl")),
        repoRole: .role(.web),
        route: try #require(Route(cli: "override", model: "m", effort: "e"))
    )
    let table = RoutingTable(base: base, overrides: [override])
    #expect(table.entries.count == 2)
    #expect(table.entries[0].repoRole == .role(.backend))
    #expect(table.entries[1].repoRole == .role(.web))
}

@Test("RoutingTable(base:overrides:) replaces fallbacks even when primary route is identical")
func replaceFallbacksWhenKeyMatches() throws {
    let baseRoute = try #require(Route(cli: "claude", model: "sonnet", effort: "medium"))
    let baseFallback = try #require(Route(cli: "codex", model: "gpt-5.4", effort: "medium"))
    let base = [
        RoutingEntry(kind: .any, route: baseRoute, fallbacks: [baseFallback])
    ]

    let overrideRoute = try #require(Route(cli: "claude", model: "sonnet", effort: "medium"))
    let override = RoutingEntry(kind: .any, route: overrideRoute, fallbacks: [])
    let table = RoutingTable(base: base, overrides: [override])

    #expect(table.entries.count == 1)
    #expect(table.entries[0].route == baseRoute)
    #expect(table.entries[0].fallbacks.isEmpty)  // Fallbacks replaced, not kept
}

// MARK: - Invalid Projects

@Test("override-undeclared-cli: bad Project is invalid, good Project loads")
func invalidProjectHasNoRoutingTable() throws {
    let configuration = try Configuration.load(directory: set("override-undeclared-cli"))

    let good = try projectID("good")
    let bad = try projectID("bad")

    #expect(configuration.routingTable(for: good) != nil)
    #expect(configuration.routingTable(for: bad) == nil)
}
