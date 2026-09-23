import Foundation

/// The Operator's settle gesture (roadmap P10.9; spec: morning-report/triage-the-morning) reads the
/// Feature Issue's workflow state tri-state: *unsettled*, *kept in flight*, or *released*.
///
/// `keptInFlight` and `released` are the **working names** for the two Linear workflow states the
/// gesture offers — not final. The probe naming the real states (risks.md gate G-6) has not run yet,
/// so ``BoardProvisioner`` still deliberately provisions no group for them. This is the one place the
/// names are spelled, so a later probe answer changes one file. Any Feature Issue workflow state that
/// is not one of these two reads as *unsettled* — including no board wired at all, in which case the
/// settle gesture is never read.
public enum SettleValue: String, Equatable, Sendable, CaseIterable {
    case keptInFlight = "Kept in Flight"
    case released = "Released"

    /// Reads a Feature Issue's workflow state name as a settle value; nil for anything else, which
    /// reads as *unsettled*.
    public init?(workflowStateName: String) {
        guard let match = Self.allCases.first(where: { $0.rawValue == workflowStateName }) else { return nil }
        self = match
    }
}
