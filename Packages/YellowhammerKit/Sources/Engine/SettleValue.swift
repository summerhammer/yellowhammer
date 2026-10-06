import Domain
import Foundation

/// The Operator's settle gesture (roadmap P10.9; spec: morning-report/triage-the-morning) reads the
/// Feature Issue's workflow state tri-state: *unsettled*, *kept in flight*, or *abandoned*.
///
/// `keptInFlight` and `abandoned` are the names for the two Linear workflow states the
/// gesture offers (Gate G-6 ruling: risks.md#decision-gates-ruling-2026-09-15; OQ128). Any Feature Issue workflow state that
/// is not one of these two reads as *unsettled* — including no board wired at all, in which case the
/// settle gesture is never read.
public enum SettleValue: String, Equatable, Sendable, CaseIterable {
    case keptInFlight = "Kept in Flight"
    case abandoned = "Abandoned"

    /// Reads a Feature Issue's workflow state name as a settle value; nil for anything else, which
    /// reads as *unsettled*.
    public init?(workflowStateName: String) {
        guard let match = Self.allCases.first(where: { $0.rawValue == workflowStateName }) else { return nil }
        self = match
    }

    /// The workflow state a Feature Issue transitions to when reset to *unsettled* (Gate G-6).
    public static let resetTargetState: CardState = .todo

    /// Whether this settle value requires a daily reset back to unsettled prior to the subsequent morning triage.
    public var requiresDailyReset: Bool {
        switch self {
        case .keptInFlight: true
        case .abandoned: false
        }
    }
}
