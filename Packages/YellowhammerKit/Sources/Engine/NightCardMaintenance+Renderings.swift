import Domain
import Foundation
import Journal

extension NightCardMaintenance {
    /// The completed Night Card's renderings, the full one first, then each more compacted (see
    /// ``NightCardCompaction``). Delivery writes the first that fits the description budget.
    func completedRenderings(night: NightRecord) throws -> [String] {
        // This Act renders the summary before its own terminal event, so the Night Summary counts it as ended.
        let renderingRunID = outbox.runID
        let verdict = try NightSummary.verdictLine(night: night, journal: journal, renderingRunID: renderingRunID)
        let failureLines = try NightSummary.failureLines(
            night: night, journal: journal, renderingRunID: renderingRunID,
            consecutiveAuthoringFaultsMax: bounds.consecutiveAuthoringFaultsMax
        )
        let findings = try authoringLines(night: night)
        let cardLines = try NightSummary.cardLines(night: night, journal: journal)
        let dispositionLines = try NightSummary.dispositionLines(night: night, journal: journal)
        let pullRequestLines = try NightSummary.pullRequestLines(night: night, journal: journal)
        let answerLines = try NightSummary.answerLines(night: night, journal: journal)
        let anomalies = try NightSummary.anomalyLines(night: night, journal: journal)
        let crashesAndReclaims = try NightSummary.crashesAndReclaimsLines(night: night, journal: journal)
        let leftoverProcesses = try NightSummary.leftoverProcessLines(night: night, journal: journal)
        let exceptions = try NightSummary.exceptionLines(
            night: night, journal: journal, renderingRunID: renderingRunID
        )
        let boundsLines = try self.boundsLines(night: night)
        let standingItems = try standingItemLines()
        let unadoptedCards = try NightSummary.unadoptedCardLines(night: night, journal: journal)
        let inFlightFeature = try NightSummary.inFlightFeatureLines(night: night, journal: journal)
        let instrumentedRates = try NightSummary.instrumentedRateLines(night: night, journal: journal, bounds: bounds)
        let cardShortLines = try NightSummary.cardShortLines(night: night, journal: journal)
        // The full rendering first, then each more compacted one: delivery writes the first that fits the
        // description budget. The key is that of the full rendering.
        let ladder = NightCardCompaction.ladder(
            cards: cardLines.count,
            standing: max(standingItems.count, unadoptedCards.count, inFlightFeature.count),
            exceptions: exceptions.count
        )
        var renderings: [String] = []
        for compaction in ladder {
            let rendered = NightCardBlock.completed(
                night: night, projectID: journal.projectID, verdictLine: verdict, failureLines: failureLines,
                authoringFindings: findings,
                cardLines: cardLines, dispositionLines: dispositionLines, pullRequestLines: pullRequestLines,
                answerLines: answerLines, anomalies: anomalies, crashesAndReclaims: crashesAndReclaims,
                leftoverProcesses: leftoverProcesses,
                exceptions: exceptions, bounds: boundsLines, standingItems: standingItems,
                unadoptedCards: unadoptedCards, inFlightFeature: inFlightFeature,
                instrumentedRates: instrumentedRates,
                cardShortLines: cardShortLines, compaction: compaction
            )
            if renderings.last != rendered { renderings.append(rendered) }
        }
        return renderings
    }
}
