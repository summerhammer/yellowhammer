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
        case .routeExhausted(let cardID, let issueID, let reason),
             .overrideRefused(let cardID, let issueID, let reason):
            ["card_id": String(cardID), "issue_id": issueID, "reason": reason]
        case .attemptEnded(let cardID, let issueID, let attemptID, let route, let outcome, let routeExcluded):
            [
                "attempt_id": String(attemptID), "card_id": String(cardID), "issue_id": issueID,
                "outcome": outcome, "route_cli": route.cli, "route_effort": route.effort,
                "route_excluded": routeExcluded ? "true" : "false", "route_model": route.model
            ]
        case .routeRetried(let cardID, let issueID, let attemptID, let route, let differentRoute):
            [
                "attempt_id": String(attemptID), "card_id": String(cardID),
                "different_route": differentRoute ? "true" : "false", "issue_id": issueID,
                "route_cli": route.cli, "route_effort": route.effort, "route_model": route.model
            ]
        case .budgetEpochReset(let cardID, let issueID, let from, let to, let reason):
            [
                "card_id": String(cardID), "from_epoch": String(from), "issue_id": issueID,
                "reason": reason, "to_epoch": String(to)
            ]
        case .expiredCardLeasesSwept(let cycleID, let reclaimedCardIDs):
            [
                "cycle_id": String(cycleID),
                "reclaimed_card_ids": reclaimedCardIDs.map(String.init).joined(separator: ",")
            ]
        case .boardStateReposted(let cards):
            ["cards": String(cards)]
        case .repoLanesDerived(let cycleID, let lanes):
            ["cycle_id": String(cycleID), "lanes": lanes.joined(separator: ",")]
        case .repoLaneStarted(let repository, let cards):
            ["cards": String(cards), "repository": repository]
        case .repoLaneEnded(let repository, let cardsRun, let failure, let cardsSkipped):
            {
                var dict: [String: String] = [
                    "cards_run": String(cardsRun), "cards_skipped": String(cardsSkipped), "repository": repository
                ]
                if let failure {
                    dict["failure"] = failure
                }
                return dict
            }()
        case .readinessCheckPassed(let cardID, let issueID):
            ["card_id": String(cardID), "issue_id": issueID]
        case .readinessCheckFailed(let cardID, let issueID, let failures):
            [
                "card_id": String(cardID), "issue_id": issueID,
                "failures": failures.joined(separator: "\u{1F}")
            ]
        case .cardDiverged(let cardID, let issueID, let repository, let changedPaths):
            [
                "card_id": String(cardID), "issue_id": issueID, "repository": repository,
                "changed_paths": changedPaths.joined(separator: "\u{1F}")
            ]
        case .transcriptionStampVoided(let cardID, let issueID, let repository):
            ["card_id": String(cardID), "issue_id": issueID, "repository": repository]
        case .clauseMinted(let issueID, let cid):
            ["issue_id": issueID, "cid": cid]
        case .clauseInvalidated(let issueID, let cid, let cause):
            ["issue_id": issueID, "cid": cid, "cause": cause]
        case .clauseDeleted(let issueID, let cid):
            ["issue_id": issueID, "cid": cid]
        case .protectedPathRefused(let cardID, let issueID, let repository, let declaredPath, let protectedPath):
            [
                "card_id": String(cardID), "issue_id": issueID, "repository": repository,
                "declared_path": declaredPath, "protected_path": protectedPath
            ]
        case .cardRunStep(let cardID, let issueID, let step, let detail):
            {
                var dict: [String: String] = ["card_id": String(cardID), "issue_id": issueID, "step": step.rawValue]
                if let detail {
                    dict["detail"] = detail
                }
                return dict
            }()
        case .checkRan(let cardID, let issueID, let attemptID, let result, let exitStatus, let output):
            {
                var dict: [String: String] = [
                    "card_id": String(cardID), "issue_id": issueID, "attempt_id": String(attemptID),
                    "result": result.rawValue
                ]
                if let exitStatus {
                    dict["exit_status"] = String(exitStatus)
                }
                if let output {
                    dict["output"] = output
                }
                return dict
            }()
        }
    }
}
