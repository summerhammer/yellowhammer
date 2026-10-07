import Domain

/// Thrown by ``EngineInvocation/boardPreflight()`` when part of the Project's board scope is unresolved
/// (OQ85, OQ136): the Act does no work. `steps` is every unresolved item and what to do about it, in
/// report order; `items` names just the items, in the same order.
public struct BoardScopeUnresolved: Error, Equatable, CustomStringConvertible {
    public var steps: [String]
    public var items: [String]

    public init(steps: [String], items: [String]) {
        self.steps = steps
        self.items = items
    }

    /// The local halted notification's copy: the items first, so a banner that cuts it short still
    /// names them (OQ85 item 2), then the fix.
    public var notificationReason: String {
        "No work ran: the Linear board is not fully provisioned: " + items.joined(separator: "; ")
            + ". Re-run `yh setup` — `yh doctor` lists every item."
    }

    public var description: String {
        "The Project's board scope is unresolved, so this Act did no work. Re-run `yh setup`, or create the "
            + "item in Linear (`yh doctor` lists what is missing): " + steps.joined(separator: "; ")
    }
}

extension EngineInvocation {
    /// Everything an Act checks about its board before it creates the Night Card or does any work: the
    /// identity is accepted (``authorizationPreflight()``), then the board scope is resolved (OQ85,
    /// OQ136) — the four provisioned `started` workflow states, the `Card Type` and `Block Reason` label
    /// groups with their children, and the `Override` label group (its presence only: its children are
    /// Routes, which no Act requires).
    ///
    /// The clock rule (OQ93(f) as widened by OQ136): every halt in which no Act read the board spends
    /// no `overdue_nights_max`; the test is that no Act read the board, not the halt's cause. This runs
    /// before the Night Card, the opening readiness read, the trigger and the Act's work, so an Act
    /// halted here reads no Card and advances no clock (UnansweredCardClock, Refusal and Authoring Halt
    /// clocks) — for the author, build and land Acts alike, and for both causes (authorization,
    /// unresolved board scope). OQ135: a Worktree-name collision halt is thrown later, after the build
    /// Act's clock ran, so it still counts.
    func boardPreflight() async throws {
        try await authorizationPreflight()
        try await resolveBoardScope()
    }

    /// Reads the board's scope with no create (`BoardProvisioner.verify`) and refuses when any item
    /// needs a fix. A read failure (network, etc.) propagates unchanged, as a generic halt.
    private func resolveBoardScope() async throws {
        guard let board else { return }
        let report = try await BoardProvisioner.verify(
            using: board.provisioning, projectName: journal.projectID.rawValue,
            routingTable: RoutingTable(entries: [])
        )
        let unfinished = report.unfinishedItems
        guard unfinished.isEmpty else {
            throw BoardScopeUnresolved(steps: unfinished.map(\.message), items: unfinished.map(\.item))
        }
    }

    /// The Act's first Linear call, before the Night Card, the trigger, or any work (roadmap P17.5) —
    /// so a refused identity halts before any board work is attempted. A non-auth failure here
    /// (network, etc.) is not treated as a halt: it is ignored, and the Night Card open right after
    /// this call meets the same error on its own terms.
    func authorizationPreflight() async throws {
        guard let board else { return }
        do {
            _ = try await board.reading.identity()
        } catch {
            if error.isLinearAuthorizationFailure { throw error }
        }
    }
}
