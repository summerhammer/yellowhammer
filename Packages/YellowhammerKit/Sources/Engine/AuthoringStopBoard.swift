import Domain
import Foundation
import Journal

/// The board plumbing an Authoring Halt and a Refusal share and nothing else (roadmap P9.8): create — or
/// re-enter — the Feature Issue in Waiting on You and append a comment naming what stopped authoring.
///
/// Both kinds use ONE create key per selection generation (``createKey(_:_:)``), so a Feature that first
/// halts and is later refused still has exactly one Feature Issue, while a name selected again after its
/// Feature was authored and closed opens a new one instead of resolving to the closed Feature's issue.
/// A repeat stop of either kind is `alreadyApplied` through the Outbox: no second
/// Feature Issue and no second workflow-state write while already in Waiting on You, only one more
/// comment (keyed per Night). When the Feature returned to contention, a newly opened stop transitions
/// it back to Waiting on You under an idempotent re-entry key.
enum AuthoringStopBoard {
    /// Posts the create and the comment, when this invocation has an Outbox and a Board. `recordIssue`
    /// is handed the Feature Issue's id before the comment is posted, so the Journal row carries it.
    static func post(
        feature: FeatureName, body: String, context: ActContext,
        reopenKey: String? = nil, commentSuffix: String? = nil, recordIssue: (String) throws -> Void,
        recordState: ((BoardObjectID) throws -> Void)? = nil
    ) async throws {
        guard let outbox = context.outbox, let board = context.board else { return }
        let scope = try await BoardStateScope.resolve(using: board)
        guard let featureLabelID = scope.labels.cardType[.featureCard] else {
            throw DispositionLabelsError.missing(
                group: BoardProvisioner.cardTypeGroup, label: CardType.featureCard.rawValue
            )
        }
        let waitingOnYouID = try scope.id(for: .waitingOnYou)
        let assignee = await context.operatorIdentity.assignee(on: board.reading)

        let generation = try context.journal.authoredFeatureCount(feature: feature.rawValue)
        let issueKey = createKey(feature, generation: generation)
        let draft = BoardIssueDraft(
            team: scope.team, title: feature.rawValue, description: ManagedBlockFence.initialDescription(rendered: ""),
            labels: [featureLabelID], workflowState: waitingOnYouID, assignee: assignee
        )
        let delivery = try await outbox.post(OutboxWrite(key: issueKey, write: .createIssue(draft, parentKey: nil)))

        let createdID: BoardObjectID?
        let newlyCreated: Bool
        switch delivery.outcome {
        case .applied(let id):
            createdID = id
            newlyCreated = true
        case .alreadyApplied(let id):
            createdID = id
            newlyCreated = false
        default:
            if let result = delivery.entry.result {
                createdID = BoardObjectID(rawValue: result)
            } else {
                createdID = nil
            }
            newlyCreated = false
        }
        // A repeat stop's create is already accepted, so the Outbox delivers nothing new and reports no id:
        // the Feature Issue is then the current generation's one that either kind's Journal row already holds.
        let known = try knownIssueID(feature, context.journal)
        guard let createdID = createdID ?? known else { return }
        try recordIssue(createdID.rawValue)
        if newlyCreated { try recordState?(waitingOnYouID) }

        if let reopenKey, !newlyCreated {
            var change = scope.labels.change(cardType: .featureCard)
            change.workflowState = waitingOnYouID
            _ = try await outbox.post(OutboxWrite(
                key: reopenKey, write: .updateIssue(issue: createdID, change: change, undo: nil)
            ))
            try recordState?(waitingOnYouID)
        }

        let commentStamp = commentSuffix ?? context.night.nightStart.rawValue
        let commentKey = generation == 0
            ? "feature:\(feature.rawValue):halt:\(commentStamp):comment"
            : "feature:\(feature.rawValue):halt:\(generation):\(commentStamp):comment"
        _ = try await outbox.post(OutboxWrite(key: commentKey, write: .createComment(issue: createdID, body: body)))
    }
}

extension AuthoringStopBoard {
    /// The Outbox key a stop creates its Feature Issue under. Generation 0 is the key older Journals already
    /// hold entries under, so it stays byte-identical; later generations get their own.
    static func createKey(_ feature: FeatureName, generation: Int) -> String {
        generation == 0
            ? "feature:\(feature.rawValue):halt:create"
            : "feature:\(feature.rawValue):halt:\(generation):create"
    }

    /// ``createKey(_:generation:)`` for the Feature's current selection generation in `journal`.
    static func createKey(_ feature: FeatureName, _ journal: JournalStore) throws -> String {
        createKey(feature, generation: try journal.authoredFeatureCount(feature: feature.rawValue))
    }

    /// The Feature Issue id of the Feature's current selection generation: the newest Refusal or Authoring
    /// Halt issue id that no `feature` row holds yet. An id a Feature row holds belongs to a Feature already
    /// authored (and perhaps closed), so a stop of a newly selected Feature never reuses it. Nil when none.
    static func knownIssueID(_ feature: FeatureName, _ journal: JournalStore) throws -> BoardObjectID? {
        // A later list position breaks a createdAt tie toward the higher id.
        var candidates: [StopIssue] = []
        for refusal in try journal.refusals(feature: feature) {
            if let id = refusal.issueID {
                candidates.append(StopIssue(createdAt: refusal.createdAt, position: candidates.count, id: id))
            }
        }
        for halt in try journal.authoringHalts(feature: feature) {
            if let id = halt.issueID {
                candidates.append(StopIssue(createdAt: halt.createdAt, position: candidates.count, id: id))
            }
        }
        let open = try candidates.filter { try journal.feature(issueID: $0.id) == nil }
        let newest = open.max { ($0.createdAt, $0.position) < ($1.createdAt, $1.position) }
        return newest.map { BoardObjectID(rawValue: $0.id) }
    }

    private struct StopIssue {
        let createdAt: Date
        let position: Int
        let id: String
    }
}
