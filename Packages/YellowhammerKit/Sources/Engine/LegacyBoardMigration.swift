import Domain
import Foundation
import Journal

/// The legacy Board migration (roadmap P22.9; spec: board-projection/provision-the-board, "Repeatable
/// migration before validation"). Runs once per Project Journal, in every Act, after the Night Card is live
/// and before the trigger and any dependent work, and converts what the retired taxonomy still means on
/// **tracked** issues only:
///
/// - a tracked Feature Card in `Kept in Flight` moves to the team's native `started` state, one in
///   `Abandoned` to its native `canceled` state (`NativeStateSelection`, the retired states excluded), through
///   the Outbox and conditioned on the retired state (P22.4), so a Card a human has already moved is left
///   where they put it. Acceptance is never inferred from `Todo`;
/// - a tracked Work Card's legacy `Override` label becomes its `Card override:` field, only when the field is
///   empty. Several pins, or a pin that disagrees with an explicit field, are kept as they are, surfaced as a
///   conflict, and nothing is chosen. The Operator's own set or clear of the field completes the conversion
///   (``JournalStore/noteCardOverrideEdited(issueID:lines:)``), after which the pin is never restored;
/// - a pending Outbox write that would set a retired state or add a retired label is superseded;
/// - the retired `Block Reason` labels, and the `Override` labels once their intent is durable, are
///   unassigned from tracked issues. A team label, group or state is never deleted.
///
/// "Tracked" is what the Journal holds: the Feature in flight and the Work Cards of its Cycle. An issue the
/// Journal does not hold is never read or written. The migration is versioned (``version``): its progress is
/// the `legacy_board_conversion` table, and every board write has a deterministic Outbox key, so a run
/// interrupted anywhere replays to the same end without a duplicate write. Its writes carry no Card Lease
/// (`cardID` nil): they run outside a Card run, and the Act's Lease guards them.
///
/// Pre-1.0 every Journal schema bump recreates the Journal, so a current install tracks no pre-release
/// issue and the migration finds nothing; it exists for spec conformance and for any tracked issue a
/// retired taxonomy item reaches after an upgrade.
struct LegacyBoardMigration {
    /// The migration's version: a row an older version wrote is read again.
    static let version = 1

    let board: ActBoard
    let outbox: Outbox

    private var journal: JournalStore { outbox.journal }
    private var projectKey: String { LegacyBoardConversion.projectKey }

    /// One run. Throws what the board or the Journal throws; ``EngineInvocation`` decides what defers.
    func run() async throws {
        if let done = try journal.legacyConversion(issueID: projectKey, kind: .project),
           done.status == .complete, done.version >= Self.version {
            return
        }
        let scope = try await BoardStateScope.resolve(using: board)
        let states = try await board.provisioning.workflowStates(team: scope.team)
        let labels = try await board.provisioning.labels(team: scope.team)
        let custom = Set([CardState.waitingOnYou, .blocked].compactMap { scope.states[$0] })
        let taxonomy = LegacyBoardTaxonomyView(states: states, labels: labels, customStateIDs: custom)
        guard !taxonomy.isEmpty else {
            try record(issueID: projectKey, kind: .project, status: .complete)
            return
        }

        try supersedePending(taxonomy)
        var open = false
        var keys = Accepted()
        guard let targets = try trackedTargets() else { return }
        for target in targets {
            guard let object = try await board.reading.issue(BoardObjectID(rawValue: target.issueID)),
                  object.archivedAt == nil
            else { continue }
            var removable = false
            switch target {
            case .feature(let issueID):
                try planSettle(issueID: issueID, object: object, taxonomy: taxonomy, scope: scope, accepted: &keys)
            case .card(let card):
                let plan = try planOverride(card: card, object: object, taxonomy: taxonomy, accepted: &keys)
                removable = plan.removable
                open = open || plan.conflict
            }
            try planLabelRemoval(
                issueID: target.issueID, object: object, taxonomy: taxonomy, includingOverride: removable,
                accepted: &keys
            )
        }

        _ = try await outbox.deliverPending()
        try finish(keys, conflictsOpen: open || keys.deferred)
    }

    /// After delivery: a settle whose entry left `pending` is complete, and the whole migration is complete when
    /// nothing is still pending and no conflict awaits the Operator.
    private func finish(_ keys: Accepted, conflictsOpen: Bool) throws {
        func isPending(_ key: String) throws -> Bool {
            try journal.outboxEntry(clientID: outbox.clientID(for: key))?.state == .pending
        }
        for (issueID, key) in keys.settles where try !isPending(key) {
            try record(issueID: issueID, kind: .settle, status: .complete)
        }
        let anyPending = try keys.all.contains(where: isPending)
        if !conflictsOpen, !anyPending {
            try record(issueID: projectKey, kind: .project, status: .complete)
        }
    }

    /// The Outbox keys one run accepted, for checking what delivery left pending.
    private struct Accepted {
        var all: [String] = []
        var settles: [(issueID: String, key: String)] = []
        /// Something could not be planned this Act (no native state to move to): the migration stays open.
        var deferred = false

        mutating func add(_ key: String, settle issueID: String? = nil) {
            all.append(key)
            if let issueID { settles.append((issueID, key)) }
        }
    }

    // MARK: - Tracked issues

    private enum Target {
        case feature(String)
        case card(CardRecord)

        var issueID: String {
            switch self {
            case .feature(let issueID): issueID
            case .card(let card): card.issueID
            }
        }
    }

    /// The Feature in flight and the Work Cards of its Cycle that the board has not lost; nil when the Journal
    /// holds more than one open Cycle. That breaks "one in-flight Feature" and is reported by the Acts that
    /// depend on it: the migration reads nothing rather than guess which Cycle is tracked, and stays open.
    private func trackedTargets() throws -> [Target]? {
        let flight: (feature: FeatureRecord, cycleID: Int64)?
        do {
            flight = try journal.inFlightFeature()
        } catch JournalError.multipleOpenCycles {
            return nil
        }
        guard let flight else { return [] }
        let cards = try journal.cards(cycleID: flight.cycleID).filter { !$0.isRemovedFromBoard }
        return [.feature(flight.feature.issueID)] + cards.map(Target.card)
    }

    // MARK: - Retired settlement states

    /// Accepts the move of a tracked Feature Card out of a retired settlement state, once; nothing when the
    /// Card is not in one or was already converted.
    private func planSettle(
        issueID: String, object: BoardObject, taxonomy: LegacyBoardTaxonomyView, scope: BoardStateScope,
        accepted: inout Accepted
    ) throws {
        guard let retired = taxonomy.settleStates[object.workflowState.id] else { return }
        if let row = try journal.legacyConversion(issueID: issueID, kind: .settle),
           row.status == .complete, row.version >= Self.version {
            return
        }
        let target = retired.name == LegacyBoardTaxonomy.keptInFlight ? scope.states[.inProgress] : scope.canceledState
        guard let target else {
            try observe(
                "migration-deferred", issueID: issueID,
                detail: "no native state to move '\(retired.name)' to; the team has none of that category"
            )
            accepted.deferred = true
            return
        }
        try record(issueID: issueID, kind: .settle, status: .planned, detail: retired.id.rawValue)
        let key = "legacy:v\(Self.version):settle:\(issueID):\(retired.id.rawValue)"
        _ = try outbox.accept(OutboxWrite(
            key: key,
            write: .updateIssue(
                issue: BoardObjectID(rawValue: issueID), change: BoardIssueChange(workflowState: target),
                undo: nil
            ),
            expectedState: retired.id
        ))
        accepted.add(key, settle: issueID)
    }

    // MARK: - Legacy Override labels

    private struct OverridePlan {
        /// The Override labels may be unassigned: their intent is durable in the field.
        var removable = false
        var conflict = false
    }

    /// Converts a tracked Work Card's legacy `Override` pin to the field, or surfaces a conflict.
    private func planOverride(
        card: CardRecord, object: BoardObject, taxonomy: LegacyBoardTaxonomyView, accepted: inout Accepted
    ) throws -> OverridePlan {
        let pins = Self.pins(on: object, taxonomy: taxonomy)
        guard !pins.isEmpty else { return OverridePlan() }
        if let row = try journal.legacyConversion(issueID: card.issueID, kind: .override) {
            return OverridePlan(removable: row.status != .conflict, conflict: row.status == .conflict)
        }
        let held = try journal.cardOverrideLines(cardID: card.id)
        let reading = CardOverrideField.reading(of: held)
        if pins.count == 1, let pin = pins.first {
            switch reading {
            case .unset:
                try record(issueID: card.issueID, kind: .override, status: .converted, detail: pin)
                let key = "legacy:v\(Self.version):override:\(card.issueID)"
                accepted.add(key)
                _ = try outbox.accept(OutboxWrite(
                    key: key,
                    write: .updateManagedBlockLine(
                        issue: BoardObjectID(rawValue: card.issueID), prefix: CardOverrideField.prefix,
                        line: CardOverrideField.prefix + " " + pin
                    ),
                    revalidates: false
                ))
                return OverridePlan(removable: true)
            case .value(let value) where value == pin:
                try record(issueID: card.issueID, kind: .override, status: .complete, detail: pin)
                return OverridePlan(removable: true)
            case .value, .malformed:
                break
            }
        }
        let account = "legacy Override \(pins.map { "`\($0)`" }.joined(separator: ", ")) against the field "
            + (held.isEmpty ? "(empty)" : held.map { "`\($0)`" }.joined(separator: ", "))
        try record(issueID: card.issueID, kind: .override, status: .conflict, detail: account)
        try observe("override-conflict", issueID: card.issueID, detail: account)
        let conflictKey = "legacy:v\(Self.version):conflict:\(card.issueID)"
        accepted.add(conflictKey)
        _ = try outbox.accept(OutboxWrite(
            key: conflictKey,
            write: .createComment(
                issue: BoardObjectID(rawValue: card.issueID),
                body: "The retired `Override` label and this Card's `Card override:` field disagree (\(account)). "
                    + "Yellowhammer chose neither. Set or clear the `Card override:` line to settle it; "
                    + "until you do, the label is left on the Card."
            )
        ))
        return OverridePlan(conflict: true)
    }

    /// The distinct legacy `Override` labels on `object`, as the board spells them.
    private static func pins(on object: BoardObject, taxonomy: LegacyBoardTaxonomyView) -> [String] {
        var seen: Set<String> = []
        return object.labels.compactMap { name in
            guard let child = taxonomy.overrideLabels[name.lowercased()], seen.insert(child.name).inserted
            else { return nil }
            return child.name
        }
    }

    // MARK: - Retired labels

    /// Unassigns the retired labels from a tracked issue: `Block Reason` children always (the cause is Card
    /// content), `Override` children only once their intent is durable.
    private func planLabelRemoval(
        issueID: String, object: BoardObject, taxonomy: LegacyBoardTaxonomyView, includingOverride: Bool,
        accepted: inout Accepted
    ) throws {
        var ids: Set<BoardObjectID> = []
        for name in object.labels {
            if let id = taxonomy.blockReasonLabels[name.lowercased()] { ids.insert(id) }
            if includingOverride, let child = taxonomy.overrideLabels[name.lowercased()] { ids.insert(child.id) }
        }
        guard !ids.isEmpty else { return }
        let sorted = ids.map(\.rawValue).sorted()
        let key = "legacy:v\(Self.version):labels:\(issueID):\(sorted.joined(separator: ","))"
        accepted.add(key)
        _ = try outbox.accept(OutboxWrite(
            key: key,
            write: .updateIssue(
                issue: BoardObjectID(rawValue: issueID),
                change: BoardIssueChange(removeLabels: sorted.map { BoardObjectID(rawValue: $0) }), undo: nil
            ),
            revalidates: false
        ))
    }

    // MARK: - Queued legacy writes

    /// Supersedes every pending write that would set a retired state or add a retired label: it was decided
    /// under a taxonomy that no longer means anything, and the next Delta Read recomputes from the board.
    private func supersedePending(_ taxonomy: LegacyBoardTaxonomyView) throws {
        let retiredLabels = taxonomy.retiredLabelIDs
        for entry in try journal.pendingOutboxEntries() {
            guard let write = try? JSONDecoder().decode(BoardWrite.self, from: Data(entry.payload.utf8)),
                  case .updateIssue(_, let change, _) = write
            else { continue }
            let setsRetiredState = change.workflowState.map { taxonomy.settleStates[$0] != nil } ?? false
            guard setsRetiredState || !retiredLabels.isDisjoint(with: change.addLabels) else { continue }
            _ = try journal.markOutboxSuperseded(
                id: entry.id,
                reason: "the write sets a retired Yellowhammer state or label, which has no meaning any more; "
                    + "the Delta Read recomputes from the board"
            )
            try outbox.append(.boardWriteSuperseded(
                clientID: entry.clientID, operation: entry.operation, issueID: entry.issueID,
                expectedState: entry.expectedStateID, observedState: nil
            ))
        }
    }

    // MARK: - Recording

    private func record(
        issueID: String, kind: LegacyConversionKind, status: LegacyConversionStatus, detail: String? = nil
    ) throws {
        try journal.recordLegacyConversion(
            issueID: issueID, kind: kind, status: status, detail: detail, version: Self.version,
            runID: outbox.runID
        )
    }

    private func observe(_ kind: String, issueID: String, detail: String) throws {
        try outbox.append(.legacyBoardObserved(kind: kind, issueID: issueID, detail: detail))
    }
}
