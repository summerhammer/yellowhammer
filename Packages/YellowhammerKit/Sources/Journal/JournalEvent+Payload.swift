import Domain
import Foundation
// swiftlint:disable file_length

extension JournalEvent {
    /// Encodes this event as a payload dictionary with sorted keys (for byte-stable storage).
    var payload: [String: String]? {
        switch self {
        case .actStarted, .actEnded: nil
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
        case .linearAuthorizationHalted: nil
        case .appInstallationTokenRefresh(let refresh): Self.payload(of: refresh)
        case .mainlineFetchFailed(let repository, let reason):
            ["reason": reason, "repository": repository]
        case .absentNightDetected(let nightStart):
            ["night_start": nightStart.rawValue]
        case .authoringNoWorkAvailable: nil
        case .authoringSkippedFeatureInFlight(let featureIssueID):
            ["feature_issue_id": featureIssueID]
        case .authoringPredecessorNotLanded(let featureIssueID, let repositories):
            [
                "feature_issue_id": featureIssueID,
                "repositories": repositories.joined(separator: "\u{1F}")
            ]
        case .authoringPredecessorIndeterminate(let featureIssueID, let repositories):
            [
                "feature_issue_id": featureIssueID,
                "repositories": repositories.joined(separator: "\u{1F}")
            ]
        case .predecessorWalkSkippedReleasedFeature(let featureIssueID):
            ["feature_issue_id": featureIssueID]
        case .predecessorAncestryObserved(let featureIssueID, let mergedRepositories, let unmergedRepositories):
            [
                "feature_issue_id": featureIssueID,
                "merged_repositories": mergedRepositories.joined(separator: "\u{1F}"),
                "unmerged_repositories": unmergedRepositories.joined(separator: "\u{1F}")
            ]
        case .mainlineConflictDetected(let featureIssueID, let repository, let paths):
            [
                "feature_issue_id": featureIssueID,
                "repository": repository,
                "paths": paths.joined(separator: "\u{1F}")
            ]
        case .managedBlockDelimiterBroken(let issueID):
            ["issue_id": issueID]
        case .notificationDeliveryFailed(let notification, let reason):
            ["notification": notification, "reason": reason]
        case .rateBudgetExhausted(let degradation, let installation):
            Self.rateBudgetPayload(degradation: degradation, installation: installation)
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
        case .humanCardComment(let cardID, let commentID, let commentedAt):
            ["card_id": String(cardID), "comment_id": commentID,
             "commented_at": JournalStore.timestamp(commentedAt)]
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
        case .protectedPathRefused, .cardQuestionAsked: waitingOnYouPayload
        case .waitingOnYouReplyRecorded, .waitingOnYouReplyBanked: waitingOnYouReplyPayload
        case .cardRunStep(let cardID, let issueID, let step, let detail):
            {
                var dict: [String: String] = ["card_id": String(cardID), "issue_id": issueID, "step": step.rawValue]
                if let detail {
                    dict["detail"] = detail
                }
                return dict
            }()
        case .featureAuthoringAccepted(let payload):
            payload.eventPayload
        case .featureAuthored(let payload):
            [
                "name": payload.name, "group_key": payload.groupKey, "feature_issue_id": payload.featureIssueID,
                "cycle_id": String(payload.cycleID), "card_count": String(payload.cardCount),
                "adopted_count": String(payload.adoptedCount)
            ]
        case .featureAuthoringFailed, .featureBreakdownRejected, .authoringDispatched, .featureSelectionFailed:
            authoringFaultPayload
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
        case .attemptWorkPreserved(let cardID, let issueID, let attemptID, let ref, let commit, let resetTo):
            [
                "attempt_id": String(attemptID), "card_id": String(cardID), "commit": commit,
                "issue_id": issueID, "ref": ref, "reset_to": resetTo
            ]
        case .failureCauseRecorded(let cardID, let issueID, let cause, let causeHash, let recurrenceCount):
            [
                "card_id": String(cardID), "cause": cause, "cause_hash": causeHash, "issue_id": issueID,
                "recurrence_count": String(recurrenceCount)
            ]
        case .laneHoleRecorded(let cardID, let issueID, let repository, let state):
            [
                "card_id": String(cardID), "issue_id": issueID,
                "repository": repository, "state": state.rawValue
            ]
        case .cardReclaimed(let cardID, let issueID, let previousRunID, let attemptID, let outcome, let routeExcluded):
            {
                var dict: [String: String] = [
                    "card_id": String(cardID), "issue_id": issueID, "previous_run_id": previousRunID.rawValue,
                    "route_excluded": routeExcluded ? "true" : "false"
                ]
                if let attemptID {
                    dict["attempt_id"] = String(attemptID)
                }
                if let outcome {
                    dict["outcome"] = outcome
                }
                return dict
            }()
        case .cardReclaimDeferred(let cardID, let issueID, let previousRunID, let remaining):
            [
                "card_id": String(cardID), "issue_id": issueID, "previous_run_id": previousRunID.rawValue,
                "remaining": String(remaining)
            ]
        case .agentCLIProcessSpawned(let cardID, let issueID, let attemptID, let pass, let cli):
            [
                "card_id": String(cardID), "issue_id": issueID, "attempt_id": String(attemptID),
                "pass": pass.rawValue, "cli": cli
            ]
        case .rehearsalFixtureAnswered(let cardID, let issueID, let attemptID, let pass, let fixture):
            [
                "card_id": String(cardID), "issue_id": issueID, "attempt_id": String(attemptID),
                "pass": pass.rawValue, "fixture": fixture
            ]
        case .cardCommitTrailerMissing(let cardID, let issueID, let attemptID, let commit):
            [
                "card_id": String(cardID), "issue_id": issueID, "attempt_id": String(attemptID),
                "commit": commit
            ]
        case .cardCommitTrailersUnread(let cardID, let issueID, let attemptID, let commit, let reason):
            [
                "card_id": String(cardID), "issue_id": issueID, "attempt_id": String(attemptID),
                "commit": commit, "reason": reason
            ]
        case .leftoverProcessRecorded(
            let cardID, let issueID, let attemptID, let pass, let pid, let commandName, let disposition, let cwd
        ):
            {
                var dict: [String: String] = [
                    "card_id": String(cardID), "issue_id": issueID, "attempt_id": String(attemptID),
                    "pass": pass.rawValue, "pid": String(pid), "command_name": commandName,
                    "disposition": disposition.rawValue
                ]
                if let cwd {
                    dict["cwd"] = cwd
                }
                return dict
            }()
        case .featureSelected(let payload):
            {
                var dict: [String: String] = [
                    "name": payload.name, "reasoning": payload.reasoning,
                    "repositories": payload.repositories.joined(separator: "\u{1F}"),
                    "adopted_card_issue_ids": payload.adoptedCardIssueIDs.joined(separator: "\u{1F}"),
                    "unadopted_card_issue_ids": payload.unadoptedCardIssueIDs.joined(separator: "\u{1F}")
                ]
                if let precededBy = payload.precededBy {
                    dict["preceded_by"] = precededBy
                }
                if let followedBy = payload.followedBy {
                    dict["followed_by"] = followedBy
                }
                if let seam = payload.seam {
                    dict["seam"] = seam
                }
                return dict
            }()
        case .featureAuthoringHalted(let name, let reasonKind, let detail):
            {
                var dict: [String: String] = ["name": name, "reason_kind": reasonKind]
                if let detail {
                    dict["detail"] = detail
                }
                return dict
            }()
        case .refusalOpened(let feature, let consecutiveRefusals, let clauses, let depth):
            Self.refusalPayload(feature, consecutiveRefusals, clauses, depth)
        case .refusalRepeated(let feature, let consecutiveRefusals, let clauses, let depth):
            Self.refusalPayload(feature, consecutiveRefusals, clauses, depth)
        case .refusalExpired(let feature, let issueID, let unansweredNights, let bound):
            {
                var dict: [String: String] = [
                    "feature": feature, "unanswered_nights": String(unansweredNights), "bound": String(bound)
                ]
                if let issueID {
                    dict["issue_id"] = issueID
                }
                return dict
            }()
        case .refusalCountReset(let feature):
            ["feature": feature]
        case .landStep(let step, let repository, let outcome, let detail):
            {
                var dict: [String: String] = ["step": step.rawValue, "outcome": outcome.rawValue]
                if let repository {
                    dict["repository"] = repository
                }
                if let detail {
                    dict["detail"] = detail
                }
                return dict
            }()
        case .cycleLanded(let cycleID): ["cycle_id": String(cycleID)]
        case .featureVerified, .featureReturned, .cycleArchived, .featureClosedByMerge,
            .noPushedBranchOutcome:
            landActPayload
        case .refusalAnswered, .authoringHaltOpened, .authoringHaltRepeated, .authoringHaltExpired,
            .authoringHaltCleared:
            authoringStopPayload
        case .featureSettled, .featureReleased, .settleValueNotHonoured: settlePayload
        case .cardUnansweredBoundFired: cardUnansweredBoundFiredPayload
        case .adoptionRefused, .cardAdopted, .adoptionUntestable: adoptionEventPayload
        case .featureReselected: featureReselectedPayload
        case .reselectionBoundReached: reselectionBoundReachedPayload
        case .refusalPromotedToStandingItem: refusalPromotedToStandingItemPayload
        case .cardPromotedToStandingItem: cardPromotedToStandingItemPayload
        case .projectRemoved: projectRemovedPayload
        }
    }
}
