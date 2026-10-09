import Domain
import Foundation
import Journal

// The P9.1 quiet-authoring-reasons section, split out of NightCardMaintenance.swift to keep that
// struct under the type body length limit.

extension NightCardMaintenance {
    public func recordAuthoring(night: NightRecord) async throws {
        _ = try await open(night: night)
        let night = try journal.night(id: night.id) ?? night
        if !night.isOpen {
            _ = try await acceptCompletion(night: night)
            return
        }
        guard let issueID = night.nightCardIssueID else { return }
        let findings = try authoringLines(night: night)
        let rendered = NightCardBlock.opened(night: night, projectID: journal.projectID, authoringFindings: findings)
        let hash = ManagedBlockFence.sha256(rendered)
        let write = OutboxWrite(
            key: Self.authoringKey(nightStart: night.nightStart, issueID: issueID, hash: hash),
            write: .rewriteManagedBlock(issue: BoardObjectID(rawValue: issueID), rendered: rendered)
        )
        _ = try outbox.accept(write)
    }

    /// This Night's quiet authoring reasons (P9.1), one line each, deduplicated (a forced re-run may
    /// record the same reason twice in one Night) and in the order the Journal recorded them — plus, for
    /// every `featureAuthoringAccepted` plan this Night with no later `featureAuthored` /
    /// `featureAuthoringFailed` for the same group key, a line saying the board is still being written
    /// (roadmap P9.10): decided here, not in ``authoringLine(for:)`` alone, because whether a plan is
    /// still pending depends on the *rest* of this Night's events — so the line disappears on a later
    /// render of the same Night once the plan resolves.
    func authoringLines(night: NightRecord) throws -> [String] {
        var seen: Set<String> = []
        var lines: [String] = []
        var acceptedOrder: [String] = []
        var acceptedPlans: [String: FeatureAuthoringAcceptedPayload] = [:]
        var resolvedGroupKeys: Set<String> = []
        for record in try journal.events() where record.nightID == night.id {
            if let line = Self.authoringLine(for: record.event, journal: journal), seen.insert(line).inserted {
                lines.append(line)
            }
            switch record.event {
            case .featureAuthoringAccepted(let plan):
                if acceptedPlans[plan.groupKey] == nil { acceptedOrder.append(plan.groupKey) }
                acceptedPlans[plan.groupKey] = plan
            case .featureAuthored(let payload):
                resolvedGroupKeys.insert(payload.groupKey)
            case .featureAuthoringFailed(_, let groupKey, _):
                resolvedGroupKeys.insert(groupKey)
            default:
                break
            }
        }
        for groupKey in acceptedOrder where !resolvedGroupKeys.contains(groupKey) {
            guard let plan = acceptedPlans[groupKey] else { continue }
            lines.append("""
                Authoring Feature `\(plan.name)` was accepted onto the board but is not yet fully \
                delivered: the board is still being written. Not a halt.
                """)
        }
        return lines
    }

    private static func renderFeatureReference(issueID: String, journal: JournalStore?) -> String {
        if let journal, let feature = try? journal.feature(issueID: issueID) {
            if let issueURL = feature.issueURL, !issueURL.isEmpty {
                return "[\(feature.displayIdentifier)](\(issueURL))"
            }
            return "`\(feature.displayIdentifier)`"
        }
        return "`\(issueID)`"
    }

    // One case per authoring-line event: a growing enumeration, not a complexity problem to refactor.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func authoringLine(for event: JournalEvent, journal: JournalStore? = nil) -> String? {
        switch event {
        case .authoringSkippedFeatureInFlight(let featureIssueID):
            let featureRef = renderFeatureReference(issueID: featureIssueID, journal: journal)
            return """
                Authoring was skipped: Feature \(featureRef) is already in flight for this Project. \
                A quiet Night, not a failure.
                """
        case .authoringPredecessorNotLanded(let featureIssueID, let repositories):
            let named = repositories.joined(separator: ", ")
            let featureRef = renderFeatureReference(issueID: featureIssueID, journal: journal)
            return """
                Authoring was skipped: predecessor Feature \(featureRef) has not landed in \(named). \
                A quiet Night, not a failure.
                """
        case .authoringPredecessorIndeterminate(let featureIssueID, let repositories):
            let named = repositories.joined(separator: ", ")
            let featureRef = renderFeatureReference(issueID: featureIssueID, journal: journal)
            return """
                Authoring was skipped: predecessor Feature \(featureRef)'s Feature Branch could not be \
                found in \(named). A quiet Night, not a failure.
                """
        case .predecessorWalkSkippedReleasedFeature(let featureIssueID):
            let featureRef = renderFeatureReference(issueID: featureIssueID, journal: journal)
            return """
                Feature \(featureRef) was abandoned: tonight's work is not built on it. The \
                predecessor-ancestry gate walked past it to the Feature before it.
                """
        case .authoringNoWorkAvailable:
            return """
                Nothing was selectable to author (`AuthoringNoWorkAvailable`). A quiet Night, not a failure.
                """
        case .featureSelected(let payload):
            let repositories = payload.repositories.joined(separator: ", ")
            return "Selected Feature `\(payload.name)`, touching \(repositories)."
        case .featureAuthoringHalted(let name, let reasonKind, let detail):
            let named = detail.map { " (\($0))" } ?? ""
            return """
                Authoring halted for Feature `\(name)`: \(reasonKind)\(named). Waiting on You: requires \
                an Operator turn to clear.
                """
        case .refusalOpened(let name, _, let clauses, let depth),
            .refusalRepeated(let name, _, let clauses, let depth):
            let named = clauses.isEmpty ? "" : " Uncitable clauses: \(clauses)."
            return """
                Feature `\(name)` was refused: its specification was too thin to cite a Definition of \
                Done.\(named) Re-selection depth: \(depth). Waiting on You: Refusal requires an Operator \
                turn to answer.
                """
        case .featureAuthoringFailed(let name, _, let reason), .featureBreakdownRejected(let name, let reason):
            return authoringFaultLine(feature: name, reason: reason)
        case .featureClosedByMerge(_, let featureIssueID, let repositories, let carriedForward, _, _):
            let named = repositories.joined(separator: ", ")
            let featureRef = renderFeatureReference(issueID: featureIssueID, journal: journal)
            return """
                Feature \(featureRef) closed by merge: its Feature Branches reached mainline in \
                \(named). Its Cycle is archived unverified; \(carriedForward.count) Cards carried forward, \
                Blocked awaiting Adoption.
                """
        case .featureSelectionFailed(let reason):
            return """
                Selecting a Feature failed: \(reason). Nothing was written to the board, so there is no \
                Feature card to open and nothing to answer; the author Act stood down without authoring. \
                The next author Act selects afresh.
                """
        case .featureSettled(_, let featureIssueID, let acceptedCards, _):
            let featureRef = renderFeatureReference(issueID: featureIssueID, journal: journal)
            return """
                Feature \(featureRef) was settled *kept in flight*: it stays in flight. \
                \(acceptedCards.count) green Cards recorded as accepted.
                """
        case .featureReleased(_, let featureIssueID, let carriedForward, _, let abandonedRepositories, _):
            let abandoned = abandonedRepositories.isEmpty ? "none" : abandonedRepositories.joined(separator: ", ")
            let featureRef = renderFeatureReference(issueID: featureIssueID, journal: journal)
            return """
                Feature \(featureRef) was settled *abandoned*: stop-with-salvage. \
                \(carriedForward.count) Cards carried forward, Blocked awaiting Adoption; abandoned pull \
                requests: \(abandoned). This Feature Issue is not archived and stays re-enterable.
                """
        case .settleValueNotHonoured(let featureIssueID, let value, let reason):
            let featureRef = renderFeatureReference(issueID: featureIssueID, journal: journal)
            return """
                Feature \(featureRef)'s settle read `\(value)`, not honoured: \(reason). Treated as \
                unsettled.
                """
        case .featureReselected, .reselectionBoundReached, .refusalPromotedToStandingItem,
            .cardPromotedToStandingItem:
            // P11.6's own lines live in NightCardMaintenance+Bounds.swift, split out to keep this
            // function under the length limit.
            return boundsAuthoringLine(for: event)
        default:
            return nil
        }
    }

    /// The exception wording an authoring fault reads as (roadmap P9.10): a rolled-back Outbox group
    /// and a breakdown validation rejection say exactly the same thing — neither ever wrote to the
    /// board, so there is no Feature card to open and nothing to answer, and the author Act stood down
    /// without authoring. Never "halt"; never "A quiet Night, not a failure" (that phrase is reserved
    /// for a quiet skip, not a fault).
    private static func authoringFaultLine(feature name: String, reason: String) -> String {
        """
        Authoring Feature `\(name)` failed: \(reason). Nothing was written to the board, so there is no \
        Feature card to open and nothing to answer; the author Act stood down without authoring. The \
        next author Act authors it afresh.
        """
    }
}
