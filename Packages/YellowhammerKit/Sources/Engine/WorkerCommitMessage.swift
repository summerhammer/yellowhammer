import Domain
import Foundation
import Journal

/// The worker pass's commit message (roadmap P19.4): the Project's `commit_message` Message Template
/// rendered with the Card's token values. Pure; the Card run fetches the inputs.
enum WorkerCommitMessage {
    /// What fills the template's tokens. `workCardKey` and `featureKey` are the human Linear identifiers and
    /// are empty when the board object was unavailable (never Linear's opaque id).
    struct Inputs: Equatable {
        var workCardKey: String
        var workCardTitle: String
        var featureKey: String
        var featureTitle: String
        var repository: String
        var story: String?
    }

    static func render(template: MessageTemplate, changeType: ChangeType, inputs: Inputs) -> String {
        let epic = inputs.story.flatMap { SpecCitation($0).epic }
        return template.render([
            .type: changeType.rawValue,
            .title: inputs.featureTitle,
            .key: inputs.featureKey,
            .repository: inputs.repository,
            .workCardKey: inputs.workCardKey,
            .workCardTitle: inputs.workCardTitle,
            .story: inputs.story ?? "",
            .scope: epic.map { "(\($0))" } ?? ""
        ])
    }

    /// The `<epic>/<story>` ID of the first clause, in clause order, whose citation is a story ID; nil
    /// when no clause cites a story.
    static func story(clauses: [ClauseRecord], description: String?) -> String? {
        ClauseOrder.inClauseOrder(clauses, description: description)
            .lazy.compactMap { SpecCitation($0.locationID).story }.first
    }
}
