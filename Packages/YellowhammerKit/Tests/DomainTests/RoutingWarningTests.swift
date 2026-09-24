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
        let table = RoutingTable(entries: [entry])
        #expect(table.warnings == [.singleCLI(entry.key, cli: "claude")])
    }

    @Test("An entry that mixes CLIs across its fallbacks warns nothing")
    func mixedCLIsWarnNothing() {
        let entry = RoutingEntry(route: route("claude", "sonnet"), fallbacks: [route("codex", "gpt-5.4")])
        let table = RoutingTable(entries: [entry])
        #expect(table.warnings.isEmpty)
    }

    @Test("Warnings are reported in entry order")
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
            .singleCLI(singleCLIEntry.key, cli: "codex")
        ])
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
}
