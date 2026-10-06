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
    @Test("A table Route pinned whole resolves to exactly that Route, whatever the Kind, Repo Role and exclusions")
    func tableRouteBeatsSelectionAndExclusion() throws {
        let cards = [(kind("impl.boilerplate"), RepoRole.backend), (kind("review"), .web), (kind("impl"), .backend)]
        for (kind, role) in cards {
            let request = RouteRequest(
                kind: kind, repoRole: role, override: Override(label: "codex/gpt-5.4/medium"),
                excludedRoutes: [codexMedium, claudeSonnet, claudeHaiku]
            )
            let resolved = try resolved(try resolver().resolve(request))
            #expect(resolved.route == codexMedium)
            #expect(resolved.selectedBy == .override)
            #expect(resolved.skipped.isEmpty)
        }
    }

    @Test("A label is matched whole and case-insensitively first, so a model id containing `/` resolves")
    func labelIsMatchedWholeFirst() throws {
        let slashed = route("openrouter", "anthropic/claude-opus", "high")
        let withSlash = RoutingTable(entries: table.entries + [RoutingEntry(kind: kind("docs"), route: slashed)])
        for label in ["openrouter/anthropic/claude-opus/high", "OPENROUTER/Anthropic/Claude-Opus/HIGH"] {
            let request = RouteRequest(kind: kind("impl"), repoRole: .web, override: Override(label: label))
            #expect(try resolved(try resolver(withSlash).resolve(request)).route == slashed)
        }
        let upper = RouteRequest(kind: kind("impl"), repoRole: .web, override: Override(label: "CODEX/GPT-5.4/MEDIUM"))
        #expect(try resolved(try resolver().resolve(upper)).route == codexMedium)
    }

    @Test("An off-table label splits into its three parts and resolves, with or without a matching entry")
    func offTableLabelSplits() throws {
        let offTableLabel = Override(label: "agy/gemini-3-pro/high")
        let request = RouteRequest(kind: kind("impl"), repoRole: .web, override: offTableLabel)
        let offTable = try resolved(try resolver().resolve(request))
        #expect(offTable.route == route("agy", "gemini-3-pro", "high"))
        #expect(offTable.selectedBy == .override)
        #expect(offTable.entry == RoutingEntry.Key(kind: kind("impl"), repoRole: .any))

        let noCatchAll = RoutingTable(entries: Array(table.entries.dropFirst()))
        let pin = Override(label: "claude/opus/high")
        let unmatched = RouteRequest(kind: kind("review"), repoRole: .web, override: pin)
        let pinned = try resolved(try resolver(noCatchAll).resolve(unmatched))
        #expect(pinned.route == claudeOpus)
        #expect(pinned.entry == nil)
    }

    @Test("A label that is neither a table Route nor three non-empty parts cannot resolve")
    func malformedLabelIsUnresolvable() throws {
        for label in ["agy", "agy/opus", "a/b/c/d", "a//c", "claude/opus /high"] {
            let override = Override(label: label)
            let request = RouteRequest(kind: kind("impl"), repoRole: .web, override: override)
            let refusal = try refused(try resolver().resolve(request))
            guard case .unresolvable(let refused, _) = refusal else {
                Issue.record("expected unresolvable for \(label), got \(refusal)")
                continue
            }
            #expect(refused == override)
            #expect(refusal.description.hasPrefix("Override `\(label)` cannot resolve"))
        }
    }

    @Test("No Route is built from part of an Override and part of an entry: a CLI pinned alone is refused")
    func cliAloneIsNeverFilledFromTheEntry() throws {
        // impl for web resolves to claude/opus/high; pinning `agy` alone once dispatched agy/opus/high.
        let request = RouteRequest(kind: kind("impl"), repoRole: .web, override: Override(label: "agy"))
        guard case .unresolvable = try refused(try resolver().resolve(request)) else {
            Issue.record("expected unresolvable")
            return
        }
    }

    @Test("An Override does not beat Probe failure, and fallbacks are not consulted under it")
    func overrideNeverBeatsProbeFailure() throws {
        // The entry has a healthy fallback (claude/sonnet); it must not be taken.
        let override = Override(label: "codex/gpt-5.4/medium")
        let request = RouteRequest(kind: kind("impl.api"), repoRole: .backend, override: override)
        let refusal = try refused(try resolver(probe: codexFailed).resolve(request))
        #expect(refusal == .probeFailed(
            override, cli: "codex", reason: "process containment: orphaned child after SIGKILL"
        ))
        #expect(refusal.description.contains("pins `codex`"))
    }

    @Test("No Override resolves through the entry")
    func noOverrideResolvesThroughTheEntry() throws {
        let plain = RouteRequest(kind: kind("impl.api"), repoRole: .web, excludedRoutes: [claudeOpus])
        #expect(try resolved(try resolver().resolve(plain)).selectedBy == .entry)
    }
}

@Suite("Route label shorthand")
struct RouteLabelTests {
    @Test("A label is exactly three non-empty `/`-separated parts with no whitespace")
    func threePartsOnly() {
        #expect(Route(label: "claude/opus/max") == route("claude", "opus", "max"))
        for label in ["claude/opus", "a/b/c/d", "a//c", "/b/c", "a/b/", "claude/opus /max", " claude/opus/max", ""] {
            #expect(Route(label: label) == nil, "\(label)")
        }
    }
}
