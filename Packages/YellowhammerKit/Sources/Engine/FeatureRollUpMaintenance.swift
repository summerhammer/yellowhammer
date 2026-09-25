import Domain
import Foundation
import Journal

/// Maintains a Feature Issue's Managed Block: renders its Roll-up (roadmap P12.3; spec: board-
/// projection/maintain-the-managed-block, second story) from the Journal, hashes, and conditionally
/// posts. Modelled on ``ManagedBlockMaintenance``, a Card's own maintainer, but a Feature Issue write
/// needs no Card Lease.
public struct FeatureRollUpMaintenance: Sendable {
    public let journal: JournalStore
    public let outbox: Outbox

    public init(journal: JournalStore, outbox: Outbox) {
        self.journal = journal
        self.outbox = outbox
    }

    public enum Outcome: Equatable, Sendable {
        case skipped(hash: String)  // rendered hash == last posted hash
        case posted(hash: String, delivery: OutboxDelivery)
    }

    /// Maintains a Feature that has a Cycle — in flight, or archived and not yet released — reading its
    /// member Cards, lane completion, Verification, merged fraction and Mainline Conflicts straight
    /// from the Journal. With zero Cards, the roll-up falls back to `.authoring`: a Feature with a
    /// Cycle at all is past the Refusal/Authoring Halt standing the zero-Card path reads.
    public func maintain(feature: FeatureRecord, cycleID: Int64) async throws -> Outcome {
        let observation = try FeatureMainlineObservationReader.latestAncestryObservation(
            featureIssueID: feature.issueID, journal: journal
        )
        let conflicts = try FeatureMainlineObservationReader.conflicts(
            featureIssueID: feature.issueID, unmergedRepositories: observation?.unmerged ?? [], journal: journal
        )
        let totalRepositories = try journal.touchedRepositories(featureID: feature.id).count
        let rollUp = FeatureRollUp(
            members: try members(feature: feature, cycleID: cycleID),
            lanesPushed: try journal.isCycleLanded(cycleID: cycleID),
            verificationPassed: try verificationPassed(cycleID: cycleID),
            mergedFraction: MergedFraction(mergedCount: observation?.merged.count ?? 0, totalCount: totalRepositories),
            conflictingRepositories: Array(conflicts.keys),
            pushedRepositories: try pushedRepositories(featureID: feature.id),
            issueStanding: .authoring
        )
        return try await post(issueID: feature.issueID, rollUp: rollUp)
    }

    /// Every repository whose Worktree for this Feature recorded a push (issue #161 part 2): a
    /// released Worktree still counts (``JournalStore/worktrees(featureID:)`` returns released rows
    /// too), so a lane that pushed and was already cleaned up still reads "pushed".
    private func pushedRepositories(featureID: Int64) throws -> Set<String> {
        Set(try journal.worktrees(featureID: featureID).filter { $0.pushedCommit != nil }.map(\.repository))
    }

    /// Maintains a Refusal or Authoring Halt's Feature Issue: no Cycle, no member Cards, so the
    /// roll-up is entirely the zero-Card standing's.
    public func maintain(zeroCardIssueID issueID: String, standing: FeatureIssueStanding) async throws -> Outcome {
        let rollUp = FeatureRollUp(
            members: [], lanesPushed: false, verificationPassed: false,
            mergedFraction: MergedFraction(mergedCount: 0, totalCount: 0), issueStanding: standing
        )
        return try await post(issueID: issueID, rollUp: rollUp)
    }

    /// Maintains every Feature Issue candidate this Night touches, deduplicated by issue id: the
    /// in-flight Feature, the not-yet-released predecessor (its merged fraction still moves after its
    /// Cycle archives), every Feature this Night's closure events name, and every Refusal/Authoring
    /// Halt Feature Issue not already covered by a real `FeatureRecord`. One candidate's failure never
    /// stops the rest; the first error is rethrown once every candidate has been tried, so the caller
    /// decides whether the Act should notice.
    public func maintainAll(night: NightRecord) async throws {
        var processed: Set<String> = []
        var errors: [Error] = []

        try await maintainInFlight(processed: &processed, errors: &errors)
        try await maintainPredecessor(processed: &processed, errors: &errors)
        try await maintainClosedThisNight(night, processed: &processed, errors: &errors)
        try await maintainZeroCardStandings(processed: &processed, errors: &errors)

        if let firstError = errors.first { throw firstError }
    }

    /// `EngineInvocation`'s Act-end hook: maintains every candidate, then flushes anything left pending.
    /// A no-op when this invocation has no Outbox. Called from a `try?`, since a Roll-up failure must
    /// never fail the Act.
    public static func maintainRollUps(night: NightRecord, journal: JournalStore, outbox: Outbox?) async throws {
        guard let outbox else { return }
        try await FeatureRollUpMaintenance(journal: journal, outbox: outbox).maintainAll(night: night)
        _ = try await outbox.deliverPending()
    }

    private func maintainInFlight(processed: inout Set<String>, errors: inout [Error]) async throws {
        guard let (feature, cycleID) = try journal.inFlightFeature() else { return }
        processed.insert(feature.issueID)
        if let error = await attempt({ _ = try await self.maintain(feature: feature, cycleID: cycleID) }) {
            errors.append(error)
        }
    }

    private func maintainPredecessor(processed: inout Set<String>, errors: inout [Error]) async throws {
        guard
            let predecessor = try journal.predecessorFeature().predecessor,
            !processed.contains(predecessor.feature.issueID),
            let cycleID = try journal.cycleID(featureID: predecessor.feature.id)
        else {
            return
        }
        processed.insert(predecessor.feature.issueID)
        if let error = await attempt({ _ = try await self.maintain(feature: predecessor.feature, cycleID: cycleID) }) {
            errors.append(error)
        }
    }

    private func maintainClosedThisNight(
        _ night: NightRecord, processed: inout Set<String>, errors: inout [Error]
    ) async throws {
        for (issueID, cycleID) in try closedThisNight(night) where !processed.contains(issueID) {
            guard let feature = try journal.feature(issueID: issueID) else { continue }
            processed.insert(issueID)
            if let error = await attempt({ _ = try await self.maintain(feature: feature, cycleID: cycleID) }) {
                errors.append(error)
            }
        }
    }

    private func maintainZeroCardStandings(processed: inout Set<String>, errors: inout [Error]) async throws {
        for (issueID, standing) in try zeroCardStandings() where !processed.contains(issueID) {
            guard try journal.feature(issueID: issueID) == nil else { continue }
            processed.insert(issueID)
            if let error = await attempt({
                _ = try await self.maintain(zeroCardIssueID: issueID, standing: standing)
            }) {
                errors.append(error)
            }
        }
    }

    private func attempt(_ body: () async throws -> Void) async -> Error? {
        do {
            try await body()
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Rendering and posting

    private func post(issueID: String, rollUp: FeatureRollUp) async throws -> Outcome {
        let rendered = FeatureRollUpBlock(rollUp: rollUp).render()
        let hash = ManagedBlockFence.sha256(rendered)
        if let lastHash = try journal.managedBlockLastPostedHash(issueID: issueID), lastHash == hash {
            return .skipped(hash: hash)
        }
        let write = OutboxWrite(
            key: "rollup:\(issueID):\(hash)",
            write: .rewriteManagedBlock(issue: BoardObjectID(rawValue: issueID), rendered: rendered)
        )
        return .posted(hash: hash, delivery: try await outbox.post(write))
    }

    /// The Cycle's Cards as ``RollUpMember``s: markers from ``FeatureMemberMarkers``, adoption from the
    /// latest `cardAdopted` event landing each Card in `feature`.
    private func members(feature: FeatureRecord, cycleID: Int64) throws -> [RollUpMember] {
        let cards = try journal.cards(cycleID: cycleID)
        let markers = try FeatureMemberMarkers.derive(cycleID: cycleID, journal: journal)
        let adoptions = try latestAdoptions(newFeatureIssueID: feature.issueID)
        return cards.map { card in
            RollUpMember(
                issueID: card.issueID, title: card.title, repository: card.repository,
                authoredOrder: card.authoredOrder, state: card.state, waitingReason: card.waitingReason,
                blockReason: card.blockReason, markers: markers[card.id] ?? [],
                adoptedFromFeatureIssueID: adoptions[card.id]
            )
        }
    }

    /// Every Card's latest adoption into `newFeatureIssueID`, keyed by `card.id`: later `cardAdopted`
    /// events (ascending append order) overwrite earlier ones for the same Card.
    private func latestAdoptions(newFeatureIssueID: String) throws -> [Int64: String] {
        var result: [Int64: String] = [:]
        for record in try journal.events(ofType: .cardAdopted) {
            guard case .cardAdopted(let cardID, _, let previousFeatureIssueID, let landedIn, _, _) = record.event,
                landedIn == newFeatureIssueID
            else {
                continue
            }
            result[cardID] = previousFeatureIssueID
        }
        return result
    }

    private func verificationPassed(cycleID: Int64) throws -> Bool {
        guard let verification = try journal.featureVerification(cycleID: cycleID) else { return false }
        return verification.clauses.allSatisfy { $0.verdict == .met }
    }

    // MARK: - `maintainAll` candidates

    /// The `(issueID, cycleID)` of every Feature a `featureClosedByMerge`, `featureReleased`,
    /// `cycleArchived` or `featureReturned` event stamped with `night.id` names — so the final state
    /// after closure is posted once, on the Night it closed.
    private func closedThisNight(_ night: NightRecord) throws -> [(issueID: String, cycleID: Int64)] {
        let types: [JournalEventType] = [.featureClosedByMerge, .featureReleased, .cycleArchived, .featureReturned]
        var result: [(issueID: String, cycleID: Int64)] = []
        for type in types {
            for record in try journal.events(ofType: type) where record.nightID == night.id {
                if let pair = Self.closurePair(record.event) {
                    result.append(pair)
                }
            }
        }
        return result
    }

    private static func closurePair(_ event: JournalEvent) -> (issueID: String, cycleID: Int64)? {
        switch event {
        case .featureClosedByMerge(let cycleID, let featureIssueID, _, _, _, _):
            (featureIssueID, cycleID)
        case .featureReleased(let cycleID, let featureIssueID, _, _, _, _):
            (featureIssueID, cycleID)
        case .cycleArchived(let cycleID, let featureIssueID, _, _):
            (featureIssueID, cycleID)
        case .featureReturned(let cycleID, let featureIssueID, _, _):
            (featureIssueID, cycleID)
        default:
            nil
        }
    }

    /// One Refusal or Authoring Halt row's contribution to the newest-record-across-both-tables race
    /// for its issue id: ordered by `openedNightID`, then `createdAt`; a tie (both stopped on the same
    /// Night at the same instant) prefers the Refusal, since it names the more specific finding.
    private struct ZeroCardCandidate {
        let openedNightID: Int64
        let createdAt: Date
        let isRefusal: Bool
        let standing: FeatureIssueStanding

        func isNewer(than other: ZeroCardCandidate) -> Bool {
            if openedNightID != other.openedNightID { return openedNightID > other.openedNightID }
            if createdAt != other.createdAt { return createdAt > other.createdAt }
            return isRefusal && !other.isRefusal
        }
    }

    /// Every Refusal/Authoring Halt Feature Issue's standing, sorted by issue id for a deterministic
    /// `maintainAll` order: the newest row recorded for that issue id, across both tables.
    private func zeroCardStandings() throws -> [(issueID: String, standing: FeatureIssueStanding)] {
        var candidates: [String: ZeroCardCandidate] = [:]
        for refusal in try journal.allRefusals() {
            guard let issueID = refusal.issueID else { continue }
            consider(
                ZeroCardCandidate(
                    openedNightID: refusal.openedNightID, createdAt: refusal.createdAt, isRefusal: true,
                    standing: Self.standing(refusalState: refusal.state)
                ),
                for: issueID, into: &candidates
            )
        }
        for halt in try journal.allAuthoringHalts() {
            guard let issueID = halt.issueID else { continue }
            consider(
                ZeroCardCandidate(
                    openedNightID: halt.openedNightID, createdAt: halt.createdAt, isRefusal: false,
                    standing: Self.standing(haltState: halt.state)
                ),
                for: issueID, into: &candidates
            )
        }
        return candidates.sorted { $0.key < $1.key }.map { (issueID: $0.key, standing: $0.value.standing) }
    }

    private func consider(
        _ candidate: ZeroCardCandidate, for issueID: String, into candidates: inout [String: ZeroCardCandidate]
    ) {
        if let existing = candidates[issueID], !candidate.isNewer(than: existing) { return }
        candidates[issueID] = candidate
    }

    private static func standing(refusalState: RefusalState) -> FeatureIssueStanding {
        switch refusalState {
        case .open, .standingItem: .awaitingYou(.refusal)
        case .expired: .unanswered(.refusal)
        case .answered: .authoring
        }
    }

    private static func standing(haltState: AuthoringHaltState) -> FeatureIssueStanding {
        switch haltState {
        case .open: .awaitingYou(.halt)
        case .expired: .unanswered(.halt)
        case .cleared: .authoring
        }
    }
}
