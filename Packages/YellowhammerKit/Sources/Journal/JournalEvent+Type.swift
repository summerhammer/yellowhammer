import Domain
import Foundation

// `JournalEvent.type` split out of JournalEvent.swift to keep that file under the file length limit.

extension JournalEvent {
    /// The type of this event.
    public var type: JournalEventType {
        switch self {
        case .actStarted:
            .actStarted
        case .actEnded:
            .actEnded
        case .actIdle:
            .actIdle
        case .actIncomplete:
            .actIncomplete
        case .actStoodDown:
            .actStoodDown
        case .mainlineFetchFailed:
            .mainlineFetchFailed
        case .absentNightDetected:
            .absentNightDetected
        case .authoringNoWorkAvailable:
            .authoringNoWorkAvailable
        case .authoringSkippedFeatureInFlight:
            .authoringSkippedFeatureInFlight
        case .authoringPredecessorNotLanded:
            .authoringPredecessorNotLanded
        case .authoringPredecessorIndeterminate:
            .authoringPredecessorIndeterminate
        case .predecessorWalkSkippedReleasedFeature:
            .predecessorWalkSkippedReleasedFeature
        case .predecessorAncestryObserved:
            .predecessorAncestryObserved
        case .mainlineConflictDetected:
            .mainlineConflictDetected
        case .managedBlockDelimiterBroken:
            .managedBlockDelimiterBroken
        case .notificationDeliveryFailed:
            .notificationDeliveryFailed
        case .rateBudgetExhausted:
            .rateBudgetExhausted
        case .leaseReclaimed:
            .leaseReclaimed
        case .cardLeaseReclaimed:
            .cardLeaseReclaimed
        case .nightOpened:
            .nightOpened
        case .nightClosed:
            .nightClosed
        case .nightOpenedAndDied:
            .nightOpenedAndDied
        case .managedBlockWritten:
            .managedBlockWritten
        case .nightCardOpened:
            .nightCardOpened
        case .nightCardCompleted:
            .nightCardCompleted
        case .boardWriteFailed:
            .boardWriteFailed
        case .outboxGroupRolledBack:
            .outboxGroupRolledBack
        case .cardCancelled:
            .cardCancelled
        case .cardReopened:
            .cardReopened
        case .cardRestated:
            .cardRestated
        case .cardRemovedFromBoard:
            .cardRemovedFromBoard
        case .authoringInvariantBroken:
            .authoringInvariantBroken
        case .deltaReadCompleted:
            .deltaReadCompleted
        case .cardStateTransitioned:
            .cardStateTransitioned
        case .waitingOnYouUnbacked:
            .waitingOnYouUnbacked
        case .worktreeLost:
            .worktreeLost
        case .worktreeFenced:
            .worktreeFenced
        case .worktreeNotQuiescent:
            .worktreeNotQuiescent
        case .worktreeWIPCommitted:
            .worktreeWIPCommitted
        case .worktreeReconciliationFailed:
            .worktreeReconciliationFailed
        case .routeExhausted:
            .routeExhausted
        case .overrideRefused:
            .overrideRefused
        case .attemptEnded:
            .attemptEnded
        case .routeRetried:
            .routeRetried
        case .budgetEpochReset:
            .budgetEpochReset
        case .expiredCardLeasesSwept:
            .expiredCardLeasesSwept
        case .boardStateReposted:
            .boardStateReposted
        case .repoLanesDerived:
            .repoLanesDerived
        case .repoLaneStarted:
            .repoLaneStarted
        case .repoLaneEnded:
            .repoLaneEnded
        case .readinessCheckPassed:
            .readinessCheckPassed
        case .readinessCheckFailed:
            .readinessCheckFailed
        case .cardDiverged:
            .cardDiverged
        case .transcriptionStampVoided:
            .transcriptionStampVoided
        case .clauseMinted:
            .clauseMinted
        case .clauseInvalidated:
            .clauseInvalidated
        case .clauseDeleted:
            .clauseDeleted
        case .protectedPathRefused:
            .protectedPathRefused
        case .cardRunStep:
            .cardRunStep
        case .checkRan:
            .checkRan
        case .attemptWorkPreserved:
            .attemptWorkPreserved
        case .failureCauseRecorded:
            .failureCauseRecorded
        case .laneHoleRecorded:
            .laneHoleRecorded
        case .cardReclaimed:
            .cardReclaimed
        case .cardReclaimDeferred:
            .cardReclaimDeferred
        case .agentCLIProcessSpawned:
            .agentCLIProcessSpawned
        case .rehearsalFixtureAnswered:
            .rehearsalFixtureAnswered
        case .featureSelected:
            .featureSelected
        case .featureAuthoringHalted:
            .featureAuthoringHalted
        case .featureAuthoringAccepted:
            .featureAuthoringAccepted
        case .featureAuthored:
            .featureAuthored
        case .featureAuthoringFailed:
            .featureAuthoringFailed
        case .refusalOpened:
            .refusalOpened
        case .refusalRepeated:
            .refusalRepeated
        case .refusalExpired:
            .refusalExpired
        case .refusalCountReset:
            .refusalCountReset
        case .landStep:
            .landStep
        case .cycleLanded:
            .cycleLanded
        case .refusalAnswered:
            .refusalAnswered
        case .authoringHaltOpened:
            .authoringHaltOpened
        case .authoringHaltRepeated:
            .authoringHaltRepeated
        case .authoringHaltExpired:
            .authoringHaltExpired
        case .authoringHaltCleared:
            .authoringHaltCleared
        }
    }
}
