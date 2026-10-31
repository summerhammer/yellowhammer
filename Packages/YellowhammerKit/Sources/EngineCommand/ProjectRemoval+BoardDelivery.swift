import Config
import Domain
import Engine
import Foundation
import Journal

extension ProjectRemoval {
    /// Lead draft, pending sponsor: step 7 follows successful held-Worktree handling, immediately
    /// before step 8's Journal commit and step 9's TOML deletion. No night_end duties are inherited.
    func deliverBoardForRemoval(
        journal: JournalStore, configuration: Configuration, project: ProjectConfiguration
    ) async throws {
        // Lead draft, pending sponsor: a missing connection explicitly skips the entire board step,
        // including pending entries. A configured connection that Linear refuses still fails delivery.
        guard configuration.machine.linearInstallation(for: project) != nil else {
            output("skipped removal board delivery: Linear Board Connection "
                + "\"\(project.linearInstallationName)\" is not in config.toml; "
                + "pending Outbox entries were not delivered")
            return
        }
        guard try ProjectRemovalBoardDelivery.requiresBoardDelivery(journal: journal) else { return }
        guard let bindDeliveryBoard else {
            throw ProjectRemovalDeliveryError.incomplete("the removal board capabilities were not bound")
        }
        let board = try bindDeliveryBoard(configuration, project)
        let runID = try journal.projectRemovalRunID()
        var outbox = Outbox(
            journal: journal, board: board.writing, reading: board.reading, runID: runID,
            installation: board.installation, descriptionBudget: board.descriptionBudget,
            scrub: scrub ?? NarrativeScrubBinding.source(
                mode: resolveMode(journal: journal), configuration: configuration, project: project,
                homeDirectory: homeDirectory
            ), interrupt: deliveryInterrupt
        )
        // Attended removal has a bounded pass and reports a retryable failure immediately. The entire
        // Journal transaction rolls back even if an earlier write succeeded remotely.
        outbox.transientRetry = .never
        outbox.countsTransientAttempts = false
        let bounds = NightCardMaintenance.Bounds(
            reviewRoundsMax: project.bounds.reviewRoundsMax,
            attemptsPerWorkCard: project.bounds.attemptsPerWorkCard,
            unansweredNightsMax: project.bounds.unansweredNightsMax,
            reselectionsMax: project.bounds.reselectionsMax,
            consecutiveRefusalsMax: project.bounds.consecutiveRefusalsMax,
            failedAdoptionsMax: project.bounds.failedAdoptionsMax,
            consecutiveAuthoringFaultsMax: project.bounds.consecutiveAuthoringFaultsMax,
            unmergedFeaturesMax: project.bounds.unmergedFeaturesMax,
            answerWaitMinutes: project.bounds.answerWaitMinutes
        )
        try await ProjectRemovalBoardDelivery(maintenance: NightCardMaintenance(
            journal: journal, outbox: outbox, provisioning: board.provisioning, bounds: bounds,
            mapping: project.boardMapping, footprint: journal
        )).deliver()
    }
}
