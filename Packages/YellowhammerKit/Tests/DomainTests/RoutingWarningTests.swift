import Domain
import Testing

private func route(_ cli: String, _ model: String, _ effort: String = "medium") -> Route {
    Route(cli: cli, model: model, effort: effort)!
}

@Suite("Routing warnings")
struct RoutingWarningTests {
    @Test("An empty Routing Table warns noEntries")
    func emptyTableWarnsNoEntries() {
        #expect(RoutingTable(entries: []).warnings == [.noEntries])
    }

    @Test("An entry with no fallbacks warns noFallbacks only")
    func noFallbacksWarnsOnce() {
        let entry = RoutingEntry(kind: .any, repoRole: .role(.backend), route: route("claude", "sonnet"))
        let table = RoutingTable(entries: [entry])
        #expect(table.warnings == [.noFallbacks(entry.key)])
    }

    @Test("An entry whose fallbacks all name the same CLI as the primary route warns singleCLI")
    func singleCLIWarns() {
        let entry = RoutingEntry(
            route: route("claude", "sonnet"),
            fallbacks: [route("claude", "opus"), route("claude", "haiku")]
        )
        let authoring = RoutingEntry(
            kind: .authoring,
            route: route("codex", "gpt-5.4"),
            fallbacks: [route("claude", "haiku")]
        )
        let table = RoutingTable(entries: [entry, authoring])
        #expect(table.warnings == [.singleCLI(entry.key, cli: "claude")])
    }

    @Test("An entry that mixes CLIs across its fallbacks warns nothing")
    func mixedCLIsWarnNothing() {
        let entry = RoutingEntry(route: route("claude", "sonnet"), fallbacks: [route("codex", "gpt-5.4")])
        let authoring = RoutingEntry(
            kind: .authoring,
            route: route("codex", "o3"),
            fallbacks: [route("claude", "haiku")]
        )
        let table = RoutingTable(entries: [entry, authoring])
        #expect(table.warnings.isEmpty)
    }

    @Test("Warnings are reported in entry order followed by table reachability")
    func warningsAreInEntryOrder() {
        let noFallbacksEntry = RoutingEntry(kind: Kind("impl")!, route: route("claude", "sonnet"))
        let singleCLIEntry = RoutingEntry(
            kind: Kind("review")!,
            route: route("codex", "gpt-5.4"),
            fallbacks: [route("codex", "o3")]
        )
        let mixedEntry = RoutingEntry(
            kind: Kind("authoring")!,
            route: route("claude", "sonnet"),
            fallbacks: [route("codex", "gpt-5.4")]
        )
        let table = RoutingTable(entries: [noFallbacksEntry, singleCLIEntry, mixedEntry])
        #expect(table.warnings == [
            .noFallbacks(noFallbacksEntry.key),
            .singleCLI(singleCLIEntry.key, cli: "codex"),
            .verificationRouteReachability(everyCycle: false)
        ])
    }

    @Test("Single-route table warns Verification reachability on every Cycle (#395 live check)")
    func singleRouteTableWarnsVerificationReachabilityEveryCycle() {
        let entry = RoutingEntry(route: route("claude", "sonnet"))
        let table = RoutingTable(entries: [entry])
        #expect(table.warnings == [
            .noFallbacks(entry.key),
            .verificationRouteReachability(everyCycle: true)
        ])
    }

    @Test("Catch-all entry with fallback warns Verification reachability (can fault, not every Cycle)")
    func catchAllWithFallbackWarnsVerificationReachabilityNotEveryCycle() {
        let entry = RoutingEntry(route: route("claude", "sonnet"), fallbacks: [route("codex", "gpt-5.4")])
        let table = RoutingTable(entries: [entry])
        #expect(table.warnings == [.verificationRouteReachability(everyCycle: false)])
    }

    @Test("Distinct authoring entry leaves Verification reachable and produces no reachability warning")
    func distinctAuthoringEntryProducesNoReachabilityWarning() {
        let entry = RoutingEntry(route: route("claude", "sonnet"), fallbacks: [route("codex", "gpt-5.4")])
        let authoring = RoutingEntry(
            kind: .authoring,
            route: route("codex", "o3"),
            fallbacks: [route("claude", "haiku")]
        )
        let table = RoutingTable(entries: [entry, authoring])
        #expect(table.warnings.isEmpty)
    }

    @Test("Authoring entry with fallback no Work Card can resolve to produces no reachability warning")
    func authoringFallbackProducesNoReachabilityWarning() {
        let entry = RoutingEntry(route: route("claude", "sonnet"), fallbacks: [route("codex", "gpt-5.4")])
        let authoring = RoutingEntry(
            kind: .authoring,
            route: route("claude", "sonnet"),
            fallbacks: [route("codex", "o3")]
        )
        let table = RoutingTable(entries: [entry, authoring])
        #expect(table.warnings.isEmpty)
    }

    @Test("Multiple Work Card entries with different primaries do not fault on every Cycle")
    func multipleWorkCardEntriesDoNotFaultOnEveryCycle() {
        let impl = RoutingEntry(
            kind: Kind("impl")!,
            route: route("codex", "gpt-5.4"),
            fallbacks: [route("claude", "sonnet")]
        )
        let authoring = RoutingEntry(kind: .authoring, route: route("claude", "sonnet"))
        let table = RoutingTable(entries: [impl, authoring])
        #expect(table.warnings.contains(.verificationRouteReachability(everyCycle: false)))
    }

    @Test("description names the entry by Kind and Repo Role, using glossary vocabulary")
    func descriptionNamesTheEntry() {
        let entry = RoutingEntry(kind: .any, repoRole: .role(.backend), route: route("claude", "sonnet"))
        let warning = RoutingWarning.noFallbacks(entry.key)
        #expect(warning.description.contains("kind \"*\""))
        #expect(warning.description.contains("repo_role \"backend\""))
        #expect(warning.description.contains("Card"))
        #expect(warning.description.contains("Blocked"))
        #expect(warning.description.contains("fallbacks"))
    }

    @Test("Verification reachability description uses glossary terms verbatim (everyCycle: true)")
    func verificationReachabilityDescriptionEveryCycle() {
        let warning = RoutingWarning.verificationRouteReachability(everyCycle: true)
        let text = warning.description
        #expect(text.contains("Verification"))
        #expect(text.contains("Route"))
        #expect(text.contains("Work Kind"))
        #expect(text.contains("Routing Table"))
        #expect(text.contains("VerificationDispatchFault"))
        #expect(text.contains("every Cycle"))
        #expect(text.contains("single Route every Work Card takes first"))
        #expect(text.contains("remedy: add a fallback, or an authoring entry, whose Route no Work Card can resolve to"))
    }

    @Test("Verification reachability description uses glossary terms verbatim (everyCycle: false)")
    func verificationReachabilityDescriptionNotEveryCycle() {
        let warning = RoutingWarning.verificationRouteReachability(everyCycle: false)
        let text = warning.description
        #expect(text.contains("Verification"))
        #expect(text.contains("Route"))
        #expect(text.contains("Work Kind"))
        #expect(text.contains("Routing Table"))
        #expect(text.contains("VerificationDispatchFault"))
        #expect(!text.contains("every Cycle"))
        #expect(text.contains("once a Cycle's worker Attempts have used each of those Routes"))
        #expect(text.contains("remedy: add a fallback, or an authoring entry, whose Route no Work Card can resolve to"))
    }

    @Test("An entry whose fallbacks list its primary route warns fallbackEqualsPrimary (#441)")
    func fallbackEqualsPrimaryWarns() {
        let primary = route("claude", "opus", "high")
        let entry = RoutingEntry(
            kind: .authoring,
            route: primary,
            fallbacks: [primary, route("codex", "gpt-5.4", "high")]
        )
        let table = RoutingTable(entries: [entry])
        #expect(table.warnings.contains(.fallbackEqualsPrimary(entry.key, route: primary)))
    }

    @Test("An entry with duplicate fallbacks warns duplicateFallback (#441)")
    func duplicateFallbackWarns() {
        let fallback = route("codex", "gpt-5.4", "high")
        let entry = RoutingEntry(
            kind: Kind("impl")!,
            route: route("claude", "sonnet", "medium"),
            fallbacks: [fallback, fallback]
        )
        let table = RoutingTable(entries: [entry])
        #expect(table.warnings.contains(.duplicateFallback(entry.key, route: fallback)))
    }

    @Test("An entry listing its primary route with a single CLI warns both fallbackEqualsPrimary and singleCLI")
    func fallbackEqualsPrimaryWithSingleCLIWarnsBoth() {
        let primary = route("claude", "opus", "high")
        let entry = RoutingEntry(
            kind: .authoring,
            route: primary,
            fallbacks: [primary]
        )
        let table = RoutingTable(entries: [entry])
        #expect(table.warnings.contains(.fallbackEqualsPrimary(entry.key, route: primary)))
        #expect(table.warnings.contains(.singleCLI(entry.key, cli: "claude")))
    }

    @Test("A fallback appearing multiple times warns duplicateFallback only once for that route")
    func duplicateFallbackWarnsOnlyOncePerRoute() {
        let fallback = route("codex", "gpt-5.4", "high")
        let entry = RoutingEntry(
            kind: Kind("impl")!,
            route: route("claude", "sonnet", "medium"),
            fallbacks: [fallback, fallback, fallback]
        )
        let table = RoutingTable(entries: [entry])
        let duplicates = table.warnings.filter {
            if case .duplicateFallback(entry.key, route: fallback) = $0 { return true }
            return false
        }
        #expect(duplicates.count == 1)
    }

    @Test("fallbackEqualsPrimary description names the entry and route, using glossary vocabulary")
    func fallbackEqualsPrimaryDescription() {
        let primary = route("claude", "opus", "high")
        let entry = RoutingEntry(kind: .authoring, repoRole: .any, route: primary)
        let warning = RoutingWarning.fallbackEqualsPrimary(entry.key, route: primary)
        let text = warning.description
        #expect(text.contains("kind \"authoring\""))
        #expect(text.contains("repo_role \"*\""))
        #expect(text.contains("lists its primary route (\"claude/opus/high\") among its fallbacks"))
        #expect(text.contains("Attempt"))
        #expect(text.contains("retry on a different route"))
    }

    @Test("duplicateFallback description names the entry and route, using glossary vocabulary")
    func duplicateFallbackDescription() {
        let fallback = route("codex", "gpt-5.4", "high")
        let entry = RoutingEntry(kind: Kind("impl")!, repoRole: .role(.backend), route: route("claude", "sonnet"))
        let warning = RoutingWarning.duplicateFallback(entry.key, route: fallback)
        let text = warning.description
        #expect(text.contains("kind \"impl\""))
        #expect(text.contains("repo_role \"backend\""))
        #expect(text.contains("lists fallback (\"codex/gpt-5.4/high\") more than once"))
        #expect(text.contains("Attempt"))
        #expect(text.contains("retry on a different route"))
    }
}
