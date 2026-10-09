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
}
