import Domain
import Observation

/// Ephemeral discovery state for one visible Routing form. The Operator can refresh explicitly; the form
/// keeps only the response it needs to render current choices and validate the pending save.
@MainActor
@Observable
public final class RouteModelDiscoveryState {
    public private(set) var results: [String: AgentModelDiscoveryResult] = [:]
    public private(set) var loading: Set<String> = []
    private var requestGeneration: [String: Int] = [:]
    private var executables: [String: String] = [:]
    @ObservationIgnored private let discover: @MainActor @Sendable (String, String?) async -> AgentModelDiscoveryResult

    public init(
        discover: @escaping @MainActor @Sendable (String, String?) async -> AgentModelDiscoveryResult = {
            await AgentModelDiscovery.discover(cli: $0, executable: $1)
        }
    ) {
        self.discover = discover
    }

    /// Starts discovery once per CLI for this form. Several route rows may ask at once; later rows reuse
    /// the in-flight/result state while the explicit Refresh button always performs a new request.
    public func loadIfNeeded(cli: String, executable: String?) async {
        if let knownExecutable = executables[cli], knownExecutable != (executable ?? "") {
            results[cli] = nil
            loading.remove(cli)
            requestGeneration[cli, default: 0] += 1
        }
        guard results[cli] == nil, !loading.contains(cli) else { return }
        await refresh(cli: cli, executable: executable)
    }

    /// Runs one new request. A response from an older refresh is discarded if a later refresh has started.
    public func refresh(cli: String, executable: String?) async {
        let generation = requestGeneration[cli, default: 0] + 1
        requestGeneration[cli] = generation
        executables[cli] = executable ?? ""
        loading.insert(cli)
        let result = await discover(cli, executable)
        guard requestGeneration[cli] == generation else { return }
        results[cli] = result
        loading.remove(cli)
    }

    public func result(for cli: String) -> AgentModelDiscoveryResult? { results[cli] }
    public func isLoading(cli: String) -> Bool { loading.contains(cli) }

    /// An unchanged configured CLI/model pair is preserved even when discovery cannot verify it. Every
    /// added or changed pair must match a live choice for that CLI; empty, failed and unsupported results
    /// cannot authorize a new or changed selection.
    public func isValid(_ route: RouteDraft, preserving original: RouteDraft?) -> Bool {
        if let original, route.cli == original.cli, route.model == original.model { return true }
        guard !loading.contains(route.cli), !route.model.isEmpty,
              case .live(let models)? = results[route.cli] else { return false }
        return models.contains { $0.id == route.model }
    }

    /// Validates every primary and fallback route against the multiset of original CLI/model pairs.
    /// Reordering or removing routes preserves surviving pairs; extra or changed pairs need discovery.
    public func isValid(_ entries: [RoutingEntryDraft], preserving original: [RoutingEntryDraft]) -> Bool {
        var preserved: [String: Int] = [:]
        for oldEntry in original {
            for route in [oldEntry.route] + oldEntry.fallbacks {
                preserved[identity(of: route), default: 0] += 1
            }
        }
        for entry in entries {
            for route in [entry.route] + entry.fallbacks {
                let key = identity(of: route)
                if preserved[key, default: 0] > 0 {
                    preserved[key, default: 0] -= 1
                } else if !isDiscovered(route) {
                    return false
                }
            }
        }
        return true
    }

    private func isDiscovered(_ route: RouteDraft) -> Bool {
        guard !loading.contains(route.cli), !route.model.isEmpty,
              case .live(let models)? = results[route.cli] else { return false }
        return models.contains { $0.id == route.model }
    }

    private func identity(of route: RouteDraft) -> String { "\(route.cli)\u{0}\(route.model)" }
}
