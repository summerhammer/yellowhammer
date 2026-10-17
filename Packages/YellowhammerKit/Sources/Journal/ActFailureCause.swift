import Domain
import Foundation

/// The class of one Act failure the Journal records (morning-report/disclose-a-failure#act-failure).
/// Recovery, the Health row's fix and the Sidebar's mark are all decided by it.
public enum ActFailureCause: String, Sendable, CaseIterable {
    case boardScopeUnresolved
    case overDescriptionBudget
    case noAuthoringRoute
    case invalidBreakdown
    case authoringRoutesFailed
    case authoringTransactionFailed
    case selectionFailed
    case authoringInvariantBroken
    case laneFailed
    case actIncomplete

    /// The cause as a Health row and the Sidebar mark word it.
    public var phrase: String {
        switch self {
        case .boardScopeUnresolved: "the board scope is unresolved"
        case .overDescriptionBudget: "over the description budget"
        case .noAuthoringRoute: "no authoring Route was left"
        case .invalidBreakdown: "invalid breakdown"
        case .authoringRoutesFailed: "every authoring Route failed"
        case .authoringTransactionFailed: "the authoring transaction failed"
        case .selectionFailed: "selecting a Feature failed"
        case .authoringInvariantBroken: "a Work Card broke an authoring invariant"
        case .laneFailed: "a lane failed"
        case .actIncomplete: "the Act could not complete"
        }
    }

    public static let boardScopePrefix = "The Project's board scope is unresolved"
    public static let noRouteReason = "the Routing Table has no Route left for the authoring Kind"

    /// Classifies one failure `event`, given the other events of the same run; nil when it is no failure.
    public static func classify(_ event: JournalEvent, runEvents: [JournalEvent] = []) -> ActFailureCause? {
        switch event {
        case .actIncomplete(let reason):
            let scoped = reason.hasPrefix(boardScopePrefix) || runEvents.contains {
                if case .boardScopeUnresolved = $0 { true } else { false }
            }
            return scoped ? .boardScopeUnresolved : .actIncomplete
        case .featureBreakdownRejected(_, let reason):
            return breakdown(reason)
        case .featureAuthoringFailed(_, _, let reason):
            return reason.contains(DescriptionBudgetOverrun.marker) ? .overDescriptionBudget
                : .authoringTransactionFailed
        case .featureSelectionFailed: return .selectionFailed
        case .authoringInvariantBroken: return .authoringInvariantBroken
        case .repoLaneEnded(_, _, .some, _): return .laneFailed
        default: return nil
        }
    }

    private static func breakdown(_ reason: String) -> ActFailureCause {
        if reason.contains(DescriptionBudgetOverrun.marker) { return .overDescriptionBudget }
        if reason == noRouteReason { return .noAuthoringRoute }
        if reason.contains("returned invalid output:") { return .invalidBreakdown }
        if reason.contains("; last failure:") || reason.contains(" crashed with no outcome") {
            return .authoringRoutesFailed
        }
        return .invalidBreakdown
    }
}
