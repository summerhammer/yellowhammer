import Domain
import Foundation

extension JournalEvent {
    /// Encodes this event as a payload dictionary with sorted keys (for byte-stable storage).
    var payload: [String: String]? {
        switch self {
        case .actStarted, .actEnded:
            nil
        case .actIdle(let reason):
            ["reason": reason.rawValue]
        case .actIncomplete(let reason):
            ["reason": reason]
        case .actStoodDown(let holder):
            [
                "holder_run_id": holder.runID.rawValue,
                "holder_act": holder.act.rawValue,
                "holder_claimed_at": JournalStore.timestamp(holder.claimedAt),
                "holder_expires_at": JournalStore.timestamp(holder.expiresAt),
                "holder_heartbeat_at": JournalStore.timestamp(holder.heartbeatAt),
                "holder_mode": holder.mode.rawValue
            ]
        case .mainlineFetchFailed(let repository, let reason):
            ["reason": reason, "repository": repository]
        case .absentNightDetected(let nightStart):
            ["night_start": nightStart.rawValue]
        case .authoringNoWorkAvailable:
            nil
        case .managedBlockDelimiterBroken(let issueID):
            ["issue_id": issueID]
        case .notificationDeliveryFailed(let notification, let reason):
            ["notification": notification, "reason": reason]
        case .rateBudgetExhausted(let degradation):
            ["budget": "workspace-wide", "degradation": degradation]
        case .leaseReclaimed(let previousRunID, let previousAct, let expiredAt):
            [
                "expired_at": JournalStore.timestamp(expiredAt),
                "previous_act": previousAct.rawValue,
                "previous_run_id": previousRunID.rawValue
            ]
        case .cardLeaseReclaimed(let cardID, let previousRunID, let expiredAt):
            [
                "card_id": String(cardID),
                "expired_at": JournalStore.timestamp(expiredAt),
                "previous_run_id": previousRunID.rawValue
            ]
        case .nightOpened:
            nil
        case .nightClosed(let reason):
            ["reason": reason.rawValue]
        case .nightOpenedAndDied(let nightID, let nightStart):
            ["night_id": String(nightID), "night_start": nightStart.rawValue]
        case .managedBlockWritten(let issueID, let preservedProseHash, let renderedHash):
            ["issue_id": issueID, "preserved_prose_hash": preservedProseHash,
             "rendered_hash": renderedHash]
        case .nightCardOpened(let issueID):
            ["issue_id": issueID]
        case .nightCardCompleted(let issueID):
            ["issue_id": issueID]
        case .boardWriteFailed(let clientID, let operation, let issueID, let reason):
            {
                var dict: [String: String] = [
                    "client_id": clientID.uuidString.lowercased(),
                    "operation": operation,
                    "reason": reason
                ]
                if let issueID {
                    dict["issue_id"] = issueID
                }
                return dict
            }()
        case .outboxGroupRolledBack(let groupID, let reason):
            ["group_id": groupID, "reason": reason]
        case .cardCancelled(let cardID, let issueID, let previousState):
            [
                "card_id": String(cardID),
                "issue_id": issueID,
                "previous_state": previousState.rawValue
            ]
        case .cardReopened(let cardID, let issueID, let restoredState):
            [
                "card_id": String(cardID),
                "issue_id": issueID,
                "restored_state": restoredState.rawValue
            ]
        case .cardRestated(let cardID, let issueID, let journalState, let boardState):
            [
                "board_state": boardState,
                "card_id": String(cardID),
                "issue_id": issueID,
                "journal_state": journalState.rawValue
            ]
        case .cardRemovedFromBoard(let cardID, let issueID, let how):
            ["card_id": String(cardID), "how": how, "issue_id": issueID]
        case .authoringInvariantBroken(let cardID, let issueID, let reason):
            ["card_id": String(cardID), "issue_id": issueID, "reason": reason]
        case .deltaReadCompleted(
            let objects, let comments, let ownComments, let requests,
            let since, let syncPoint
        ):
            {
                var dict: [String: String] = [
                    "comments": String(comments),
                    "objects": String(objects),
                    "own_comments": String(ownComments),
                    "requests": String(requests)
                ]
                if let since {
                    dict["since"] = JournalStore.timestamp(since)
                }
                if let syncPoint {
                    dict["sync_point"] = JournalStore.timestamp(syncPoint)
                }
                return dict
            }()
        case .cardStateTransitioned(let cardID, let issueID, let from, let to, let waitingReason, let blockReason):
            {
                var dict: [String: String] = [
                    "card_id": String(cardID), "from_state": from.rawValue,
                    "issue_id": issueID, "to_state": to.rawValue
                ]
                if let waitingReason {
                    dict["waiting_reason"] = waitingReason.rawValue
                }
                if let blockReason {
                    dict["block_reason"] = blockReason.rawValue
                }
                return dict
            }()
        case .waitingOnYouUnbacked(let issueID, let cardID, let reason):
            {
                var dict: [String: String] = ["issue_id": issueID, "reason": reason]
                if let cardID {
                    dict["card_id"] = String(cardID)
                }
                return dict
            }()
        case .worktreeLost(let featureID, let repository, let worktreeID, let path):
            [
                "feature_id": String(featureID), "path": path,
                "repository": repository, "worktree_id": worktreeID
            ]
        case .worktreeFenced(let featureID, let repository, let path, let killed):
            [
                "feature_id": String(featureID), "killed": String(killed),
                "path": path, "repository": repository
            ]
        case .worktreeNotQuiescent(let featureID, let repository, let path, let remaining):
            [
                "feature_id": String(featureID), "path": path,
                "remaining": String(remaining), "repository": repository
            ]
        case .worktreeWIPCommitted(let featureID, let repository, let wipCommit, let wipRef, let resetTo):
            {
                var dict: [String: String] = [
                    "feature_id": String(featureID), "repository": repository,
                    "wip_commit": wipCommit, "wip_ref": wipRef
                ]
                if let resetTo {
                    dict["reset_to"] = resetTo
                }
                return dict
            }()
        case .worktreeReconciliationFailed(let featureID, let repository, let path, let reason):
            [
                "feature_id": String(featureID), "path": path,
                "reason": reason, "repository": repository
            ]
        }
    }
}
