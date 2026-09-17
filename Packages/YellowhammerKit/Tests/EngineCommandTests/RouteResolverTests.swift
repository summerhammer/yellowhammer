import Domain
import Foundation
import Synchronization
import Testing

@testable import Engine

// routing/resolve-a-route-for-a-card (P7.6): resolution selects a Routing Entry by Override, then Kind
// by longest prefix, then Repo Role, and filters the entry's candidates by attempt history and Probe
// failure. Rehearsal-assertable: route resolution is on the may-assert list, and the resolver is pure
// over its inputs — the merged table, the Card's Kind and Repo Role, the Operator's Override and the
// exclusion set — with the Probe verdict read through a closure a test controls.

private func route(_ cli: String, _ model: String, _ effort: String) -> Route {
    Route(cli: cli, model: model, effort: effort)!
}

private func kind(_ string: String) -> Kind {
    Kind(string)!
}

private let claudeSonnet = route("claude", "sonnet", "medium")
private let claudeHaiku = route("claude", "haiku", "low")
private let claudeOpus = route("claude", "opus", "high")
private let codexMedium = route("codex", "gpt-5.4", "medium")
private let codexMini = route("codex", "gpt-5.4-mini", "low")
private let geminiFlash = route("gemini", "flash", "medium")

/// A table with a catch-all, a Kind-specific entry, a Repo-Role-specific entry, and one that is both.
private let table = RoutingTable(entries: [
    RoutingEntry(route: claudeSonnet, fallbacks: [codexMedium]),
    RoutingEntry(kind: kind("impl.boilerplate"), route: claudeHaiku, fallbacks: [codexMini]),
    RoutingEntry(kind: kind("impl"), repoRole: .role(.backend), route: codexMedium, fallbacks: [claudeSonnet]),
    RoutingEntry(kind: kind("impl"), route: claudeOpus, fallbacks: [codexMedium, geminiFlash])
])

/// Every CLI offered.
private let allOffered: RouteResolver.ProbeEligibility = { _ in .offered }

/// `codex` failed its Probe; the rest are offered.
private let codexFailed: RouteResolver.ProbeEligibility = { cli in
    cli == "codex" ? .excluded(reason: "process containment: orphaned child after SIGKILL") : .offered
}

private func resolver(
    _ table: RoutingTable = table, probe: @escaping RouteResolver.ProbeEligibility = allOffered
) -> RouteResolver {
    RouteResolver(table: table, probeEligibility: probe)
}

private func resolved(_ resolution: RouteResolution) throws -> ResolvedRoute {
    guard case .resolved(let resolved) = resolution else {
        throw ResolutionShape.expectedResolved(resolution)
    }
    return resolved
}

private func exhausted(_ resolution: RouteResolution) throws -> RouteExhaustion {
    guard case .exhausted(let exhaustion) = resolution else {
        throw ResolutionShape.expectedExhausted(resolution)
    }
    return exhaustion
}

private func refused(_ resolution: RouteResolution) throws -> OverrideRefusal {
    guard case .overrideRefused(let refusal) = resolution else {
        throw ResolutionShape.expectedRefused(resolution)
    }
    return refusal
}

private enum ResolutionShape: Error {
    case expectedResolved(RouteResolution)
    case expectedExhausted(RouteResolution)
    case expectedRefused(RouteResolution)
}

@Suite("Route resolution: selection")
struct RouteSelectionTests {
    @Test("Kind by longest prefix beats Repo Role: impl.boilerplate for any role over impl for backend")
    func longestKindPrefixBeatsRepoRole() throws {
        let request = RouteRequest(kind: kind("impl.boilerplate"), repoRole: .backend)
        let resolved = try resolved(try resolver().resolve(request))
        #expect(resolved.route == claudeHaiku)
        #expect(resolved.entry == RoutingEntry.Key(kind: kind("impl.boilerplate"), repoRole: .any))
        #expect(resolved.selectedBy == .entry)
        #expect(resolved.skipped.isEmpty)
    }

    @Test("At equal Kind length, the entry naming the Card's Repo Role beats the entry for any")
    func repoRoleBreaksTheKindTie() throws {
        let backend = try resolved(try resolver().resolve(RouteRequest(kind: kind("impl.api"), repoRole: .backend)))
        #expect(backend.entry == RoutingEntry.Key(kind: kind("impl"), repoRole: .role(.backend)))
        #expect(backend.route == codexMedium)

        let web = try resolved(try resolver().resolve(RouteRequest(kind: kind("impl.api"), repoRole: .web)))
        #expect(web.entry == RoutingEntry.Key(kind: kind("impl"), repoRole: .any))
        #expect(web.route == claudeOpus)
    }

    @Test("A Repo Role entry for another role never applies; an unconfigured repository matches any-role entries only")
    func otherRolesAndUnknownRepositories() throws {
        let unknownRepo = try resolved(try resolver().resolve(RouteRequest(kind: kind("impl.api"), repoRole: nil)))
        #expect(unknownRepo.entry == RoutingEntry.Key(kind: kind("impl"), repoRole: .any))

        let onlyBackend = RoutingTable(entries: [
            RoutingEntry(kind: kind("impl"), repoRole: .role(.backend), route: codexMedium)
        ])
        let web = RouteRequest(kind: kind("impl"), repoRole: .web)
        let exhaustion = try exhausted(try resolver(onlyBackend).resolve(web))
        #expect(exhaustion.entry == nil)
    }

    @Test("The catch-all takes a Kind nothing else matches; without one, nothing matches and the Card is exhausted")
    func catchAllAndNoMatch() throws {
        let caught = try resolved(try resolver().resolve(RouteRequest(kind: kind("review"), repoRole: .backend)))
        #expect(caught.entry == RoutingEntry.Key(kind: .any, repoRole: .any))
        #expect(caught.route == claudeSonnet)

        let noCatchAll = RoutingTable(entries: Array(table.entries.dropFirst()))
        let review = RouteRequest(kind: kind("review"), repoRole: .backend)
        let exhaustion = try exhausted(try resolver(noCatchAll).resolve(review))
        #expect(exhaustion.entry == nil)
        #expect(exhaustion.skipped.isEmpty)
        #expect(exhaustion.description.hasPrefix("fallbacks exhausted: no Routing Entry matches"))
    }

    @Test("Table order does not decide: the same entries reversed select the same route")
    func tableOrderIsIrrelevant() throws {
        let reversed = RoutingTable(entries: table.entries.reversed())
        let cards: [(String, RepoRole)] = [
            ("impl.boilerplate", .backend), ("impl.api", .backend), ("impl.api", .web), ("review", .web)
        ]
        for (kindName, role) in cards {
            let request = RouteRequest(kind: kind(kindName), repoRole: role)
            #expect(try resolver().resolve(request) == (try resolver(reversed).resolve(request)))
        }
    }

    @Test("Same inputs, same output: nothing is learned between resolutions")
    func resolutionIsDeterministic() throws {
        let request = RouteRequest(kind: kind("impl.api"), repoRole: .backend, excludedRoutes: [codexMedium])
        let first = try resolver(probe: codexFailed).resolve(request)
        let second = try resolver(probe: codexFailed).resolve(request)
        #expect(first == second)
    }
}

@Suite("Route resolution: filters and fallbacks")
struct RouteFilterTests {
    @Test("The primary route excluded by attempt history falls back to the first fallback")
    func historyFallsBackOnce() throws {
        let request = RouteRequest(kind: kind("impl.api"), repoRole: .web, excludedRoutes: [claudeOpus])
        let resolved = try resolved(try resolver().resolve(request))
        #expect(resolved.route == codexMedium)
        #expect(resolved.skipped == [SkippedCandidate(route: claudeOpus, reason: .attemptHistory)])
    }

    @Test("The primary and first fallback excluded fall through to the second, in configured order")
    func historyFallsBackTwice() throws {
        let request = RouteRequest(kind: kind("impl.api"), repoRole: .web, excludedRoutes: [claudeOpus, codexMedium])
        let resolved = try resolved(try resolver().resolve(request))
        #expect(resolved.route == geminiFlash)
        #expect(resolved.skipped == [
            SkippedCandidate(route: claudeOpus, reason: .attemptHistory),
            SkippedCandidate(route: codexMedium, reason: .attemptHistory)
        ])
    }

    @Test("A CLI that failed its Probe is skipped on every candidate, with the Ledger's reason")
    func probeFailureSkipsEveryCandidateOnThatCLI() throws {
        let request = RouteRequest(kind: kind("impl.api"), repoRole: .backend)
        let resolved = try resolved(try resolver(probe: codexFailed).resolve(request))
        #expect(resolved.route == claudeSonnet)
        #expect(resolved.skipped == [
            SkippedCandidate(route: codexMedium, reason: .probe("process containment: orphaned child after SIGKILL"))
        ])
    }

    @Test("A never-probed CLI is not offered: the closure's exclusion is honoured as a Probe exclusion")
    func neverProbedIsExcluded() throws {
        let neverProbed: RouteResolver.ProbeEligibility = { cli in .excluded(reason: "`\(cli)` has never been probed") }
        let request = RouteRequest(kind: kind("impl.boilerplate"), repoRole: .web)
        let exhaustion = try exhausted(try resolver(probe: neverProbed).resolve(request))
        #expect(exhaustion.entry == RoutingEntry.Key(kind: kind("impl.boilerplate"), repoRole: .any))
        #expect(exhaustion.skipped == [
            SkippedCandidate(route: claudeHaiku, reason: .probe("`claude` has never been probed")),
            SkippedCandidate(route: codexMini, reason: .probe("`codex` has never been probed"))
        ])
    }

    @Test("Zero survivors: fallbacks exhausted, and the account names every skipped route and why")
    func zeroCandidatesIsExhausted() throws {
        let request = RouteRequest(kind: kind("impl.api"), repoRole: .web, excludedRoutes: [claudeOpus, geminiFlash])
        let exhaustion = try exhausted(try resolver(probe: codexFailed).resolve(request))
        #expect(exhaustion.entry == RoutingEntry.Key(kind: kind("impl"), repoRole: .any))
        #expect(exhaustion.skipped.map(\.route) == [claudeOpus, codexMedium, geminiFlash])
        #expect(exhaustion.description.hasPrefix("fallbacks exhausted"))
        #expect(exhaustion.description.contains("`claude/opus/high` excluded by attempt history"))
        #expect(exhaustion.description.contains("`codex/gpt-5.4/medium` not offered by its Probe"))
        #expect(exhaustion.description.contains("`gemini/flash/medium` excluded by attempt history"))
    }

    @Test("The Probe verdict is read at most once per distinct CLI in one resolution")
    func probeIsAskedOncePerCLI() throws {
        let asked = Mutex<[String]>([])
        let counting: RouteResolver.ProbeEligibility = { cli in
            asked.withLock { $0.append(cli) }
            return .excluded(reason: "failed")
        }
        // impl for web: claude/opus, codex/gpt-5.4, gemini/flash — plus the two claude fallbacks would
        // repeat claude if the verdict were not remembered.
        let wide = RoutingTable(entries: [
            RoutingEntry(
                kind: kind("impl"), route: claudeOpus, fallbacks: [claudeSonnet, codexMedium, claudeHaiku, geminiFlash]
            )
        ])
        _ = try resolver(wide, probe: counting).resolve(RouteRequest(kind: kind("impl"), repoRole: .web))
        #expect(asked.withLock { $0 } == ["claude", "codex", "gemini"])
    }
}

@Suite("Route resolution: the Override")
struct RouteOverrideTests {
    @Test("A full Override beats Kind and Repo Role, and reports the entry it would have used")
    func fullOverrideBeatsSelection() throws {
        let override = Override(cli: "gemini", model: "pro", effort: "high")
        let request = RouteRequest(kind: kind("impl.boilerplate"), repoRole: .backend, override: override)
        let resolved = try resolved(try resolver().resolve(request))
        #expect(resolved.route == route("gemini", "pro", "high"))
        #expect(resolved.selectedBy == .override)
        #expect(resolved.entry == RoutingEntry.Key(kind: kind("impl.boilerplate"), repoRole: .any))
    }

    @Test("A partial Override fills the absent axes from the resolved entry's primary route, never a fallback")
    func partialOverrideFillsFromThePrimaryRoute() throws {
        // impl for backend resolves to codex/gpt-5.4/medium with fallback claude/sonnet/medium.
        let request = RouteRequest(kind: kind("impl.api"), repoRole: .backend, override: Override(effort: "high"))
        let filled = try resolved(try resolver().resolve(request))
        #expect(filled.route == route("codex", "gpt-5.4", "high"))
        #expect(filled.selectedBy == .override)

        let modelOnly = RouteRequest(kind: kind("impl.api"), repoRole: .backend, override: Override(model: "o3"))
        #expect(try resolved(try resolver().resolve(modelOnly)).route == route("codex", "o3", "medium"))
    }

    @Test("An Override beats attempt-history exclusion: the pinned route resolves although it is excluded")
    func overrideBeatsAttemptHistory() throws {
        let request = RouteRequest(
            kind: kind("impl.api"), repoRole: .backend,
            override: Override(cli: "codex", model: "gpt-5.4", effort: "medium"),
            excludedRoutes: [codexMedium, claudeSonnet]
        )
        let resolved = try resolved(try resolver().resolve(request))
        #expect(resolved.route == codexMedium)
        #expect(resolved.selectedBy == .override)
        #expect(resolved.skipped.isEmpty)
    }

    @Test("An Override does not beat Probe failure, and fallbacks are not consulted under it")
    func overrideNeverBeatsProbeFailure() throws {
        // The entry has a healthy fallback (claude/sonnet); it must not be taken.
        let request = RouteRequest(kind: kind("impl.api"), repoRole: .backend, override: Override(cli: "codex"))
        let refusal = try refused(try resolver(probe: codexFailed).resolve(request))
        #expect(refusal == .probeFailed(
            Override(cli: "codex"), cli: "codex", reason: "process containment: orphaned child after SIGKILL"
        ))
        #expect(refusal.description.contains("pins `codex`"))
    }

    @Test("A pinned entry axis on a probe-failed entry CLI is refused too: the fill comes from the entry")
    func filledCLIIsCheckedAgainstTheProbe() throws {
        // impl for backend fills cli from the entry: codex, which failed its Probe.
        let request = RouteRequest(kind: kind("impl.api"), repoRole: .backend, override: Override(effort: "high"))
        let refusal = try refused(try resolver(probe: codexFailed).resolve(request))
        guard case .probeFailed(_, let cli, _) = refusal else {
            Issue.record("expected probeFailed, got \(refusal)")
            return
        }
        #expect(cli == "codex")
    }

    @Test("An Override with an absent axis and no matching entry cannot resolve; fully pinned, it needs no entry")
    func unresolvableVersusFullyPinned() throws {
        let noCatchAll = RoutingTable(entries: Array(table.entries.dropFirst()))
        let partial = RouteRequest(kind: kind("review"), repoRole: .web, override: Override(cli: "claude"))
        let refusal = try refused(try resolver(noCatchAll).resolve(partial))
        #expect(refusal == .unresolvable(
            Override(cli: "claude"), reason: "no Routing Entry matches the Card to fill the absent model, effort axis"
        ))
        #expect(refusal.description.hasPrefix("Override `claude/-/-` cannot resolve"))

        let full = RouteRequest(
            kind: kind("review"), repoRole: .web, override: Override(cli: "claude", model: "opus", effort: "high")
        )
        let resolved = try resolved(try resolver(noCatchAll).resolve(full))
        #expect(resolved.route == claudeOpus)
        #expect(resolved.entry == nil)
    }

    @Test("No pin is no Override: an empty Override resolves exactly as no Override does")
    func emptyOverrideIsNone() throws {
        let plain = RouteRequest(kind: kind("impl.api"), repoRole: .web, excludedRoutes: [claudeOpus])
        let empty = RouteRequest(kind: kind("impl.api"), repoRole: .web, override: .none, excludedRoutes: [claudeOpus])
        #expect(Override.none.isEmpty)
        #expect(try resolver().resolve(plain) == (try resolver().resolve(empty)))
        #expect(try resolved(try resolver().resolve(empty)).selectedBy == .entry)
    }
}
