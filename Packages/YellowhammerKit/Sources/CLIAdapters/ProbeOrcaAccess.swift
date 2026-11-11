import Domain

/// Diagnostic observations supplied by the Orca adapter at the composition root. The Probe sees
/// findings, never Orca's JSON or query language. These closures cannot change dispatch or routing.
public struct ProbeOrcaAccess: Sendable {
    public let tab: @Sendable (String, WorkspaceWorktree, String, String) async -> OrcaProbeFindings
    public let history: @Sendable (String, String, String, String, String) async -> OrcaProbeFindings

    public init(
        tab: @escaping @Sendable (String, WorkspaceWorktree, String, String) async -> OrcaProbeFindings,
        history: @escaping @Sendable (String, String, String, String, String) async -> OrcaProbeFindings
    ) {
        self.tab = tab
        self.history = history
    }
}
