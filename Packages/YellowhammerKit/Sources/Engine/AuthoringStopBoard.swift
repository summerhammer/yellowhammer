import Domain
import Foundation
import Journal

/// The board plumbing an Authoring Halt and a Refusal share and nothing else (roadmap P9.8): create — or
/// re-enter — the Feature Issue in Waiting on You and append a comment naming what stopped authoring.
///
/// Both kinds use ONE create key, so a Feature that first halts and is later refused still has exactly
/// one Feature Issue. A repeat stop of either kind is `alreadyApplied` through the Outbox: no second
/// Feature Issue and no second workflow-state write, only one more comment (keyed per Night).
enum AuthoringStopBoard {
    /// Posts the create and the comment, when this invocation has an Outbox and a Board. `recordIssue`
    /// is handed the Feature Issue's id before the comment is posted, so the Journal row carries it.
    static func post(
        feature: FeatureName, body: String, context: ActContext, recordIssue: (String) throws -> Void
    ) async throws {
        guard let outbox = context.outbox, let board = context.board else { return }
        let scope = try await BoardStateScope.resolve(using: board.provisioning)
        guard let featureLabelID = scope.labels.objectType["Feature"] else {
            throw DispositionLabelsError.missing(group: BoardProvisioner.objectTypeGroup, label: "Feature")
        }
        let waitingOnYouID = try scope.id(for: .waitingOnYou)

        let createKey = "feature:\(feature.rawValue):halt:create"
        let draft = BoardIssueDraft(
            team: scope.team, title: feature.rawValue, labels: [featureLabelID], workflowState: waitingOnYouID
            // No assignee: the Operator's board identity is not wired until P11.
        )
        let delivery = try await outbox.post(OutboxWrite(key: createKey, write: .createIssue(draft, parentKey: nil)))

        let createdID: BoardObjectID?
        switch delivery.outcome {
        case .applied(let id):
            createdID = id
        case .alreadyApplied(let id):
            createdID = id
        default:
            createdID = nil
        }
        // A repeat stop's create is already accepted, so the Outbox delivers nothing new and reports no id:
        // the Feature Issue is then the one either kind's Journal row already holds.
        let known = try knownIssueID(feature, context.journal)
        guard let createdID = createdID ?? known else { return }
        try recordIssue(createdID.rawValue)
        let commentKey = "feature:\(feature.rawValue):halt:\(context.night.nightStart.rawValue):comment"
        _ = try await outbox.post(OutboxWrite(key: commentKey, write: .createComment(issue: createdID, body: body)))
    }
}

extension AuthoringStopBoard {
    /// The Feature Issue id a Refusal or Authoring Halt row already holds for `feature`, newest first.
    private static func knownIssueID(_ feature: FeatureName, _ journal: JournalStore) throws -> BoardObjectID? {
        let refused = try journal.refusals(feature: feature).compactMap(\.issueID)
        let halted = try journal.authoringHalts(feature: feature).compactMap(\.issueID)
        let ids = refused + halted
        return ids.first.map { BoardObjectID(rawValue: $0) }
    }
}
