import Domain
@testable import Engine
import Foundation
import Testing

// roadmap P9.11 (spec: routing overview, "the author Act routes through the same table"): the author
// Act resolves through the ordinary Routing Table under the reserved authoring Kind with no Repo Role.
// Key shape, merge rule and resolution are unchanged: one entry, not a second table or resolution path.

private func route(_ cli: String, _ model: String, _ effort: String) -> Route {
    Route(cli: cli, model: model, effort: effort)!
}

private let catchAll = route("claude", "sonnet", "medium")
private let authoringPrimary = route("claude", "opus", "high")
private let authoringFallback = route("codex", "gpt-5.4", "high")
private let repointed = route("codex", "gpt-5.4", "medium")
private let repointedFallback = route("claude", "sonnet", "high")

private let offered: RouteResolver.ProbeEligibility = { _ in .offered }
private let authoringRequest = RouteRequest(kind: .authoring, repoRole: nil)

private func resolvedRoutes(_ table: RoutingTable, excluded: Set<Route> = []) throws -> [Route] {
    let resolver = RouteResolver(table: table, probeEligibility: offered)
    var routes: [Route] = []
    var excludedRoutes = excluded
    while case .resolved(let resolved) = try resolver.resolve(
        RouteRequest(kind: .authoring, repoRole: nil, excludedRoutes: excludedRoutes)
    ) {
        routes.append(resolved.route)
        excludedRoutes.insert(resolved.route)
    }
    return routes
}

@Suite("The authoring Kind through the ordinary Routing Table (P9.11)")
struct AuthoringRouteResolutionTests {
    @Test("The authoring Kind is reserved: it, and anything under it, reads as reserved; other Kinds do not")
    func reservedPredicate() throws {
        #expect(Kind.authoring.isReservedForAuthoring)
        #expect(try #require(Kind("authoring.selection")).isReservedForAuthoring)
        #expect(!Kind.any.isReservedForAuthoring)
        #expect(!(try #require(Kind("impl.boilerplate"))).isReservedForAuthoring)
        #expect(Kind.authoring.description == "authoring")
    }

    @Test("An (authoring, any) entry is the one selected for a request with the authoring Kind and no Repo Role")
    func authoringEntryIsSelected() throws {
        let table = RoutingTable(entries: [
            RoutingEntry(route: catchAll),
            RoutingEntry(kind: .authoring, route: authoringPrimary, fallbacks: [authoringFallback])
        ])
        let resolver = RouteResolver(table: table, probeEligibility: offered)

        let resolution = try resolver.resolve(authoringRequest)

        guard case .resolved(let resolved) = resolution else {
            Issue.record("expected resolved, got \(resolution)")
            return
        }
        #expect(resolved.route == authoringPrimary)
        #expect(resolved.entry == RoutingEntry.Key(kind: .authoring, repoRole: .any))
        #expect(try resolvedRoutes(table) == [authoringPrimary, authoringFallback])
    }

    @Test("An entry naming a Repo Role never applies to the author Act, which resolves with no Repo Role")
    func roleNamedEntryNeverApplies() throws {
        let table = RoutingTable(entries: [
            RoutingEntry(route: catchAll),
            RoutingEntry(kind: .authoring, repoRole: .role(.backend), route: authoringPrimary)
        ])

        #expect(try resolvedRoutes(table) == [catchAll])
    }

    @Test("With no authoring entry the `*` entry applies: resolution is unchanged")
    func catchAllAppliesWithoutAnAuthoringEntry() throws {
        let table = RoutingTable(entries: [
            RoutingEntry(route: catchAll, fallbacks: [authoringFallback]),
            RoutingEntry(kind: try #require(Kind("impl")), route: authoringPrimary)
        ])

        #expect(try resolvedRoutes(table) == [catchAll, authoringFallback])
    }

    @Test("A per-Project (authoring, any) override re-points the author path, fallbacks included")
    func perProjectOverrideRepointsTheAuthorPath() throws {
        let base = [
            RoutingEntry(route: catchAll),
            RoutingEntry(kind: .authoring, route: authoringPrimary, fallbacks: [authoringFallback])
        ]
        let overrides = [
            RoutingEntry(kind: .authoring, route: repointed, fallbacks: [repointedFallback])
        ]

        let merged = RoutingTable(base: base, overrides: overrides)

        #expect(try resolvedRoutes(merged) == [repointed, repointedFallback])
        #expect(try resolvedRoutes(RoutingTable(base: base, overrides: [])) == [authoringPrimary, authoringFallback])
    }
}
