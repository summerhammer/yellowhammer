/// The board objects earlier Yellowhammer builds provisioned and the Board Simplification Ruling (2026-10-20)
/// retired: the settlement states `Kept in Flight` and `Abandoned`, and the `Block Reason` and `Override`
/// label groups. Nothing provisions, verifies or reads them any more. They are named here for exactly three
/// jobs, none of which gives them meaning: converting a tracked issue that still carries one (the legacy
/// Board migration, roadmap P22.9), keeping native `started` selection from adopting a retired state, and
/// reporting the residual taxonomy to the Operator (`yh doctor`). Team objects are never deleted.
public enum LegacyBoardTaxonomy {
    /// The retired settlement state earlier builds read as "carry on across Nights".
    public static let keptInFlight = "Kept in Flight"
    /// The retired settlement state earlier builds read as abandonment.
    public static let abandoned = "Abandoned"
    /// Both retired settlement state names.
    public static let settleStateNames = [keptInFlight, abandoned]
    /// The retired label group whose children were the Block Reason causes.
    public static let blockReasonGroup = "Block Reason"
    /// The retired label group whose children were Routes written `cli/model/effort`.
    public static let overrideGroup = "Override"

    /// Whether `state` is a retired settlement state: provisioned by name, and with the `started` category
    /// earlier builds gave it. A same-name state of another category is not one, and a name alone never
    /// makes a state Yellowhammer's.
    public static func isRetiredSettleState(_ state: BoardWorkflowState) -> Bool {
        state.category == .started && settleStateNames.contains(state.name)
    }

    /// The notice a tracked Feature Card standing in a retired settlement state is given, once.
    public static let retiredStateNotice =
        "This is a retired Yellowhammer state and has no special meaning; "
        + "move the Feature Card to Done or Cancelled to settle it."

    /// What of the retired taxonomy a team still carries, as the Operator reads it: each retired settlement
    /// state present with the `started` category, and each retired label group present (matched without
    /// regard to case, groups only). Empty for a team with none. Used to report, never to act.
    public static func residualItems(states: [BoardWorkflowState], labels: [BoardLabel]) -> [String] {
        var items = states.filter(isRetiredSettleState).map { "workflow state `\($0.name)`" }
        for group in [blockReasonGroup, overrideGroup]
        where labels.contains(where: { $0.isGroup && $0.name.lowercased() == group.lowercased() }) {
            items.append("label group `\(group)`")
        }
        return items
    }
}
