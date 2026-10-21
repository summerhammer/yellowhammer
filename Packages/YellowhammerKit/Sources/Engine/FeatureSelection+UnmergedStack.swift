import Domain
import Foundation
import Journal

extension FeatureSelection {
    /// Engine validation that a selection never names a Feature in the Unmerged Feature Stack U (roadmap P23.2;
    /// spec: feature-authoring/select-the-next-feature, `#effective-base`): that Feature is already implemented
    /// and awaits merge, and authoring it again would duplicate work the next Feature is built on. Compared by
    /// name, trimmed and case-insensitively. An authoring fault (`featureSelectionFailed`), not a halt and not a
    /// quiet Night: nothing is recorded as selected and nothing is authored. Nil when the selection names no
    /// Feature in U.
    func refuseUnmergedReselection(
        _ selected: SelectedFeature, scope: SelectionScope, context: ActContext
    ) throws -> FeatureAuthoringOutcome? {
        guard let member = scope.boardState.unmergedFeature(named: selected.name.rawValue) else { return nil }
        let repositories = member.unmergedBranches.map(\.repository).joined(separator: ", ")
        try context.journal.append(
            .featureSelectionFailed(
                reason: "selection chose Feature '\(selected.name)', which is already implemented as "
                    + "\(member.identifier) and awaits merge in \(repositories); a Feature in the unmerged "
                    + "Feature stack is never selected again"
            ),
            act: context.act, runID: context.runID, nightID: context.night.id
        )
        return .authoringRolledBack
    }
}
