import Domain
import Foundation

/// What a Feature Card's native workflow state means for scheduling (roadmap P22.2; spec: morning-report/
/// triage-the-morning, "Governing native disposition contract"). The native workflow **type** is the
/// selector; names are only product meaning. No state here resets each day: a Feature stays in whatever
/// disposition the Board holds until the Operator moves the Card.
public enum FeatureDisposition: Equatable, Sendable {
    /// `backlog` or `triage`: hold execution and new Feature selection.
    case backlog
    /// `unstarted`: accepted-plan ready.
    case ready
    /// Any other `started` state: work continues across Nights and occupies the in-flight slot.
    case continuing
    /// The custom `Waiting on You` state (a `started` state recognised before the generic type).
    case waitingOnYou
    /// The custom `Blocked` state (a `started` state recognised before the generic type).
    case blocked
    /// `completed` (native Done): Board completion. Settles the Feature as `feature completed`.
    case completed
    /// Linear's `canceled` type, which the adapter maps to ``BoardWorkflowStateCategory/shelved`` (the
    /// domain keeps one spelling for a cancelled state, whichever card it is on). Settles as abandonment.
    case canceled
    /// No state read, or a category this build does not know: never scheduled through, never a closure.
    case indeterminate

    /// The two workflow states earlier builds provisioned as the daily-reset settle gesture.
    ///
    /// Temporary legacy bridge (P22.2; P22.9 removes it): since P22.8 neither state is provisioned or
    /// verified, but a board provisioned by an earlier build may still hold a Feature Card in either.
    /// `Kept in Flight` reads as ``continuing`` and `Abandoned` as ``canceled``, ahead of the category,
    /// because both were provisioned with the `started` type. No id is persisted for them, so they are
    /// recognised by name; native `started` selection excludes them the same way (``NativeStateSelection``).
    public static let legacySettleStateNames = ["Kept in Flight", "Abandoned"]

    /// Reads `state` against `scope`: the custom `Waiting on You` and `Blocked` state ids first, then
    /// the legacy bridge, then the native category.
    public init(workflowState state: BoardWorkflowState?, scope: BoardStateScope) {
        guard let state else {
            self = .indeterminate
            return
        }
        if state.id == scope.states[.waitingOnYou] {
            self = .waitingOnYou
        } else if state.id == scope.states[.blocked] {
            self = .blocked
        } else if state.name == Self.legacySettleStateNames[0] {
            self = .continuing
        } else if state.name == Self.legacySettleStateNames[1] {
            self = .canceled
        } else {
            self = Self.disposition(of: state.category)
        }
    }

    private static func disposition(of category: BoardWorkflowStateCategory?) -> FeatureDisposition {
        switch category {
        case .backlog, .triage: .backlog
        case .unstarted: .ready
        case .started: .continuing
        case .completed: .completed
        case .shelved: .canceled
        case nil: .indeterminate
        }
    }
}
