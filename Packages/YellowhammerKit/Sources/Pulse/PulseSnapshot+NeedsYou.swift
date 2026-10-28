import Domain
import Foundation
import Journal

extension PulseSnapshot {
    // MARK: Needs you

    static func needsYou(
        _ journal: JournalStore, inFlight: (feature: FeatureRecord, cycleID: Int64)?, night: NightRecord?
    ) throws -> NeedsYou {
        let hold = try inFlight.flatMap {
            try journal.hasCycleHandoffBegun(cycleID: $0.cycleID)
                ? nil : journal.activeLandHold(cycleID: $0.cycleID)
        }
        let activeHold = night?.isOpen == true && hold?.nightID == night?.id ? hold : nil
        let cards = try journal.cards().compactMap { card -> DecisionCard? in
            guard card.state == .blocked || card.state == .waitingOnYou else { return nil }
            return DecisionCard(
                id: card.issueID,
                issueIDForDisplay: card.issueIDForDisplay ?? card.issueKey,
                title: card.displayTitle,
                state: card.state,
                blockReason: card.state == .blocked ? card.blockReason.flatMap { BlockReason(rawValue: $0) } : nil,
                repo: card.repository,
                link: LinearIssueLink.link(key: card.issueIDForDisplay ?? card.issueKey, url: card.issueURL),
                landHoldEndsAt: keepsLandFromFiring(card)
                    ? activeHold.flatMap { $0.cardIDs.contains(card.id) ? $0.endsAt : nil } : nil
            )
        }
        return NeedsYou(
            cards: cards, returnedFeature: try returnedFeature(journal, inFlight: inFlight),
            authoringDecisions: try authoringDecisions(journal)
        )
    }

    private static func keepsLandFromFiring(_ card: CardRecord) -> Bool {
        guard !card.isRemovedFromBoard else { return false }
        if card.state == .waitingOnYou { return card.waitingReason == .question }
        let reasons: Set<BlockReason> = [.checkFailure, .routeFailure, .hostCrash, .engineFault]
        let reason = card.blockReason.flatMap(BlockReason.init(rawValue:))
        return card.state == .blocked && reason.map(reasons.contains) == true
    }

    /// The Journal's Feature state once the land Act has returned the Feature to the Operator.
    private static let returnedState = "returned"

    /// The in-flight Feature as a Needs you row when the land Act returned it to the Operator.
    private static func returnedFeature(
        _ journal: JournalStore, inFlight: (feature: FeatureRecord, cycleID: Int64)?
    ) throws -> ReturnedFeature? {
        guard let inFlight, inFlight.feature.state == Self.returnedState else { return nil }
        let feature = inFlight.feature
        let key = feature.issueIDForDisplay ?? feature.issueKey
        return ReturnedFeature(
            id: feature.issueID,
            issueIDForDisplay: key,
            verification: try verificationCounts(journal, cycleID: inFlight.cycleID),
            link: LinearIssueLink.link(key: key, url: feature.issueURL)
        )
    }

    /// The verdict tally of the Cycle's recorded Verification; nil when none is recorded.
    private static func verificationCounts(_ journal: JournalStore, cycleID: Int64) throws -> VerificationCounts? {
        try journal.featureVerification(cycleID: cycleID).map { try counts(of: $0, journal, cycleID: cycleID) }
    }

    /// The tally, with the repositories that declared `check = none` when any clause was not checked.
    static func counts(of record: FeatureVerificationRecord, _ journal: JournalStore, cycleID: Int64) throws
        -> VerificationCounts {
        var counts = counts(of: record)
        if counts.notChecked > 0 {
            counts.noCheckRepositories = try journal.repositoriesDeclaringNoCheck(cycleID: cycleID)
        }
        return counts
    }

    static func counts(of record: FeatureVerificationRecord) -> VerificationCounts {
        VerificationCounts(
            met: record.clauses.count { $0.verdict == .met },
            unmet: record.clauses.count { $0.verdict == .unmet },
            unresolved: record.clauses.count { $0.verdict == .unresolved },
            notChecked: record.clauses.count { $0.verdict == .notChecked }
        )
    }
}
