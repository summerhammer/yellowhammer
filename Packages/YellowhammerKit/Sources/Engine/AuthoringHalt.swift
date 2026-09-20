import Domain
import Foundation
import Journal

/// Records an authoring halt durably before any board write, then — only when this invocation has an
/// Outbox and a Board — puts the Feature in Waiting on You naming the reason. Allocates no Worktree,
/// dispatches nothing and records no Attempt.
///
/// Shared by ``FeatureSelection`` (the seam and repository-determination halts, roadmap P9.3) and
/// ``AuthoringTransaction`` (the thin-spec Refusal, roadmap P9.5) so both route through exactly one halt
/// path: a Feature refused for either reason ends up Waiting on You the same way.
enum AuthoringHalt {
    static func record(
        feature: FeatureName, reason: AuthoringHaltReason, context: ActContext
    ) async throws -> FeatureAuthoringOutcome {
        try context.journal.append(
            .featureAuthoringHalted(name: feature.rawValue, reasonKind: reason.kind, detail: reason.detail),
            act: context.act, runID: context.runID, nightID: context.night.id
        )

        // Only the uncitable-Definition-of-Done halt is a Refusal in glossary terms (roadmap P9.7):
        // recorded durably before any board write, and — once its Refusal has expired — this halt
        // writes nothing to the board at all: the Feature Issue stays Blocked, no re-create into
        // Waiting on You and no repeated comment.
        var refusalAlreadyExpired = false
        if case .uncitableDefinitionOfDone = reason {
            let content = reason.description
            let outcome = try context.journal.recordRefusal(
                feature: feature, content: content, nightID: context.night.id,
                act: context.act, runID: context.runID
            )
            refusalAlreadyExpired = outcome.alreadyExpired
        }
        guard !refusalAlreadyExpired else {
            return .halted
        }

        guard let outbox = context.outbox, let board = context.board else {
            return .halted
        }
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
        if let createdID {
            if case .uncitableDefinitionOfDone = reason {
                try context.journal.recordRefusalIssue(feature: feature, issueID: createdID.rawValue)
            }
            let commentKey = "feature:\(feature.rawValue):halt:\(context.night.nightStart.rawValue):comment"
            _ = try await outbox.post(OutboxWrite(
                key: commentKey, write: .createComment(issue: createdID, body: reason.description)
            ))
        }
        return .halted
    }
}
