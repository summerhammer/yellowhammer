import Config
import Domain
import Testing

@Suite("Routing model selection")
@MainActor
struct RouteModelDiscoveryStateTests {
    @Test("Primary and fallback routes require discovered identifiers when new or changed")
    func validatesPrimaryAndFallbacks() async {
        let state = RouteModelDiscoveryState { cli, _ in
            switch cli {
            case "claude": .live(models: [AgentModel(id: "sonnet-v2", label: "Sonnet 2")])
            case "codex": .live(models: [AgentModel(id: "gpt-5-codex", label: "GPT-5 Codex")])
            default: .unsupported("No discovery fixture")
            }
        }
        let original = [RoutingEntryDraft(
            route: RouteDraft(cli: "claude", model: "legacy-opus", effort: "high")
        )]
        #expect(state.isValid(original, preserving: original))

        var edited = original
        edited[0].route.model = "sonnet-v2"
        edited[0].fallbacks = [
            RouteDraft(cli: "claude", model: "sonnet-v2", effort: "medium"),
            RouteDraft(cli: "codex", model: "gpt-5-codex", effort: "medium")
        ]
        #expect(!state.isValid(edited, preserving: original))
        await state.loadIfNeeded(cli: "claude", executable: "/usr/bin/claude")
        #expect(!state.isValid(edited, preserving: original))
        await state.loadIfNeeded(cli: "codex", executable: "/usr/bin/codex")
        #expect(state.isValid(edited, preserving: original))

        edited[0].fallbacks[0].model = "unlisted-model"
        #expect(!state.isValid(edited, preserving: original))
    }

    @Test("Deletion and fallback reordering preserve old pairs; an added duplicate still requires discovery")
    func preservesByIdentityRatherThanPosition() {
        let original = [
            RoutingEntryDraft(
                route: RouteDraft(cli: "claude", model: "legacy-opus", effort: "high"),
                fallbacks: [
                    RouteDraft(cli: "codex", model: "legacy-codex", effort: "medium"),
                    RouteDraft(cli: "claude", model: "legacy-sonnet", effort: "low")
                ]
            ),
            RoutingEntryDraft(route: RouteDraft(cli: "agy", model: "legacy-agy", effort: "high"))
        ]
        let state = RouteModelDiscoveryState()
        #expect(state.isValid([original[1]], preserving: original))

        var reordered = [original[0]]
        reordered[0].fallbacks = [
            RouteDraft(cli: "claude", model: "legacy-sonnet", effort: "high"),
            RouteDraft(cli: "codex", model: "legacy-codex", effort: "high")
        ]
        #expect(state.isValid(reordered, preserving: original))
        reordered[0].fallbacks.append(RouteDraft(cli: "claude", model: "legacy-opus", effort: "high"))
        #expect(!state.isValid(reordered, preserving: original))
    }

    @Test("Changed CLI clears model and needs a choice from that CLI")
    func cliSwitchRequiresChoice() async {
        var route = RouteDraft(cli: "claude", model: "opus", effort: "high")
        route.selectCLI("codex")
        #expect(route.cli == "codex")
        #expect(route.model.isEmpty)

        let original = RouteDraft(cli: "claude", model: "opus", effort: "high")
        let state = RouteModelDiscoveryState { _, _ in
            .live(models: [AgentModel(id: "gpt-5-codex", label: "GPT-5 Codex")])
        }
        #expect(!state.isValid(route, preserving: original))
        route.model = "gpt-5-codex"
        await state.loadIfNeeded(cli: "codex", executable: nil)
        #expect(state.isValid(route, preserving: original))
    }

    @Test("Each vendor accepts only its own discovered identifiers")
    func vendorChoicesAreScoped() async {
        let choices = [
            "claude": AgentModel(id: "sonnet", label: "Sonnet"),
            "codex": AgentModel(id: "gpt-5-codex", label: "GPT-5 Codex"),
            "agy": AgentModel(id: "gemini-3-pro", label: "Gemini 3 Pro")
        ]
        let state = RouteModelDiscoveryState { cli, _ in
            guard let choice = choices[cli] else { return .unsupported("Unknown CLI") }
            return .live(models: [choice])
        }
        for (cli, choice) in choices {
            await state.loadIfNeeded(cli: cli, executable: nil)
            #expect(state.isValid(RouteDraft(cli: cli, model: choice.id, effort: "medium"), preserving: nil))
            let unrelated = RouteDraft(cli: cli, model: "model-for-another-cli", effort: "medium")
            #expect(!state.isValid(unrelated, preserving: nil))
        }
    }

    @Test("Changing a configured executable discards the old model list and discovers again")
    func executableChangeInvalidatesChoices() async {
        let state = RouteModelDiscoveryState { _, executable in
            .live(models: [AgentModel(id: executable ?? "path-default", label: "CLI model")])
        }
        await state.loadIfNeeded(cli: "codex", executable: "/opt/codex-one")
        let first = RouteDraft(cli: "codex", model: "/opt/codex-one", effort: "medium")
        #expect(state.isValid(first, preserving: nil))

        await state.loadIfNeeded(cli: "codex", executable: "/opt/codex-two")
        #expect(!state.isValid(first, preserving: nil))
        #expect(state.isValid(
            RouteDraft(cli: "codex", model: "/opt/codex-two", effort: "medium"), preserving: nil
        ))
    }

    @Test(
        "Existing unavailable identifiers are preserved; empty, failed, and unsupported choices do not authorize edits"
    )
    func keepsUnavailableAndRejectsUnverifiedChange() async {
        let original = RouteDraft(cli: "claude", model: "retired-model", effort: "medium")
        let state = RouteModelDiscoveryState { cli, _ in
            switch cli {
            case "claude": .live(models: [])
            case "codex": .failed("CLI unavailable")
            default: .unsupported("No discovery method")
            }
        }
        #expect(state.isValid(original, preserving: original))
        var changed = original
        changed.model = "other"
        await state.loadIfNeeded(cli: "claude", executable: nil)
        #expect(!state.isValid(changed, preserving: original))
        changed.cli = "codex"
        await state.loadIfNeeded(cli: "codex", executable: nil)
        #expect(!state.isValid(changed, preserving: original))
        changed.cli = "other"
        await state.loadIfNeeded(cli: "other", executable: nil)
        #expect(!state.isValid(changed, preserving: original))
    }

    @Test("A newer retry response wins when an earlier request completes later")
    func newerRefreshWins() async {
        let gate = DiscoveryGate()
        let state = RouteModelDiscoveryState { cli, _ in await gate.discover(cli) }
        let first = Task { await state.refresh(cli: "codex", executable: nil) }
        await gate.waitForPending(1)
        let second = Task { await state.refresh(cli: "codex", executable: nil) }
        await gate.waitForPending(2)
        gate.resolveLast(.live(models: [AgentModel(id: "new", label: "New")]))
        await second.value
        gate.resolveFirst(.live(models: [AgentModel(id: "old", label: "Old")]))
        await first.value
        #expect(state.result(for: "codex") == .live(models: [AgentModel(id: "new", label: "New")]))
    }
}

@MainActor
private final class DiscoveryGate {
    private var pending: [CheckedContinuation<AgentModelDiscoveryResult, Never>] = []

    func discover(_ cli: String) async -> AgentModelDiscoveryResult {
        await withCheckedContinuation { pending.append($0) }
    }

    func waitForPending(_ count: Int) async {
        while pending.count < count { await Task.yield() }
    }

    func resolveFirst(_ result: AgentModelDiscoveryResult) { pending.removeFirst().resume(returning: result) }
    func resolveLast(_ result: AgentModelDiscoveryResult) { pending.removeLast().resume(returning: result) }
}
