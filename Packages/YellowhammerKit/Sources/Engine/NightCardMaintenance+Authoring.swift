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
        var rejections: [RunID: [RouteRejection]] = [:]
        for (record, event) in Self.collapsingStackFullSkips(try journal.events().filter { $0.nightID == night.id }) {
            for line in Self.bufferedRouteLines(for: record, rejections: &rejections) where seen.insert(line).inserted {
                lines.append(line)
            }
            if let line = Self.authoringLine(for: event, journal: journal), seen.insert(line).inserted {
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

    /// Each record with the event its line renders. Periodic author firings may skip on a full Unmerged Feature
    /// Stack every tick (roadmap P23.5): the Night keeps one of those skips, where the first was recorded, carrying
    /// the latest one's content, so the Night Card never grows with the number of firings.
    private static func collapsingStackFullSkips(
        _ records: [JournalEventRecord]
    ) -> [(record: JournalEventRecord, event: JournalEvent)] {
        let skips = records.filter { $0.type == .authoringSkippedUnmergedStackFull }
        guard let first = skips.first, let latest = skips.last else { return records.map { ($0, $0.event) } }
        return records.compactMap { record in
            guard record.type == .authoringSkippedUnmergedStackFull else { return (record, record.event) }
            return record.id == first.id ? (record, latest.event) : nil
        }
    }

    /// Buffers a Route rejection under its run; when that run's fault arrives, returns the buffered lines. An
    /// authoring pass's rejections are flushed by the run's `FeatureBreakdownRejected` or
    /// `FeatureSelectionFailed`; the verifier's, by the run's failed Verification land step. A walk that ended
    /// in an answer has no fault, so what it buffered is never rendered.
    private static func bufferedRouteLines(
        for record: JournalEventRecord, rejections: inout [RunID: [RouteRejection]]
    ) -> [String] {
        guard let runID = record.runID else { return [] }
        switch record.event {
        case .authoringRouteRejected(let pass, let route, _, let cause, let reason):
            rejections[runID, default: []].append(
                RouteRejection(pass: pass, route: route, cause: cause, reason: reason)
            )
            return []
        case .featureBreakdownRejected, .featureSelectionFailed:
            return flush(&rejections, runID: runID, verifier: false)
        case .landStep(.verification, _, .failed, _):
            return flush(&rejections, runID: runID, verifier: true).map { "Verification: \($0)" }
        default:
            return []
        }
    }

    /// The lines of the run's buffered rejections of the verifier pass (or of every other pass), which leave
    /// the buffer; the other pass's stay.
    private static func flush(
        _ rejections: inout [RunID: [RouteRejection]], runID: RunID, verifier: Bool
    ) -> [String] {
        let buffered = rejections[runID] ?? []
        let flushed = buffered.filter { ($0.pass == .verifier) == verifier }
        let kept = buffered.filter { ($0.pass == .verifier) != verifier }
        rejections[runID] = kept.isEmpty ? nil : kept
        return routeRejectionLines(flushed)
    }

    private struct RouteRejection {
        let pass: RunPass
        let route: String
        let cause: AuthoringRouteRejectionCause
        let reason: String
    }

    /// One line per cause, in the walk order the causes first appear: the Routes sharing it, then each
    /// Route's own one-line reason. When every reason is an overrun of the same budget the numbers fold
    /// into one (`12,153 and 11,987 of 10,000`).
    private static func routeRejectionLines(_ rejections: [RouteRejection]) -> [String] {
        var order: [AuthoringRouteRejectionCause] = []
        for rejection in rejections where !order.contains(rejection.cause) { order.append(rejection.cause) }
        return order.map { cause in
            let group = rejections.filter { $0.cause == cause }
            let routes = group.map { "`\($0.route)`" }.joined(separator: ", ")
            let overruns = group.compactMap { DescriptionBudgetOverrun.parse($0.reason) }
            let detail: String
            if group.count > 1, overruns.count == group.count, Set(overruns.map(\.budget)).count == 1 {
                let sizes = overruns.map { DescriptionBudgetOverrun.grouped($0.size) }
                let listed = sizes.dropLast().joined(separator: ", ") + " and " + sizes[sizes.count - 1]
                detail = "\(listed) of \(DescriptionBudgetOverrun.grouped(overruns[0].budget))"
            } else {
                detail = group.map { DescriptionBudgetOverrun.oneLineReason($0.reason) }.joined(separator: "; ")
            }
            return "\(routes): \(cause.phrase) — \(detail)"
        }
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

    private static func releaseGateHeldLine(
        consumer: String, producer: String, producerFeatureIssueID: String, hold: ConsumerHold,
        journal: JournalStore?
    ) -> String {
        let featureRef = renderFeatureReference(issueID: producerFeatureIssueID, journal: journal)
        if hold == .awaitingMerge {
            return "Authoring was skipped: \(consumer) consumes \(producer), awaiting the Observed Merge of "
                + "Feature \(featureRef) in \(producer). Merge its pull request. A quiet Night, not a failure."
        }
        return "Authoring was skipped: \(consumer) reads \(producer) by tag, and no release of \(producer) "
            + "contains Feature \(featureRef) yet. Cut a release of \(producer) that includes it. "
            + "A quiet Night, not a failure."
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
        case .authoringSkippedUnmergedStackFull(let features, let unmergedFeaturesMax):
            return unmergedStackFullLine(features: features, unmergedFeaturesMax: unmergedFeaturesMax, journal: journal)
        case .authoringPredecessorIndeterminate(let featureIssueID, let repositories):
            let named = repositories.joined(separator: ", ")
            let featureRef = renderFeatureReference(issueID: featureIssueID, journal: journal)
            return """
                Authoring was skipped: the pushed tip of Feature \(featureRef) in the unmerged Feature stack \
                could not be found in \(named). A quiet Night, not a failure.
                """
        case .authoringReleaseGateHeld(_, let consumer, let producer, let producerFeatureIssueID, let hold):
            return releaseGateHeldLine(
                consumer: consumer, producer: producer, producerFeatureIssueID: producerFeatureIssueID,
                hold: hold, journal: journal
            )
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
        case .authoringHaltRepair(let name, let step, let detail):
            return haltRepairLine(feature: name, step: step, detail: detail)
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
            let trimmedReason = trimTrailingPeriod(reason)
            return """
                Selecting a Feature failed: \(trimmedReason). Nothing was written to the board, so there is no \
                Feature card to open and nothing to answer; the author Act stood down without authoring. \
                The next author Act selects afresh.
                """
        case .featureCompleted(_, let featureIssueID, let carriedForward, _, let keptWorktrees):
            let featureRef = renderFeatureReference(issueID: featureIssueID, journal: journal)
            let kept = keptWorktrees.isEmpty
                ? "" : " Worktrees kept for unpushed work: \(keptWorktrees.joined(separator: ", "))."
            return """
                Feature \(featureRef) was completed on the Board: its Cycle is closed without a check, \
                Verification or merge recorded; \(carriedForward.count) Cards carried forward, Blocked \
                awaiting Adoption.\(kept)
                """
        case .featureReleased(_, let featureIssueID, let carriedForward, _, let abandonedRepositories, _):
            let abandoned = abandonedRepositories.isEmpty ? "none" : abandonedRepositories.joined(separator: ", ")
            let featureRef = renderFeatureReference(issueID: featureIssueID, journal: journal)
            return """
                Feature \(featureRef) was cancelled on the Board: stop-with-salvage. \
                \(carriedForward.count) Cards carried forward, Blocked awaiting Adoption; abandoned pull \
                requests: \(abandoned). This Feature Issue is not archived and stays re-enterable.
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

    /// The quiet skip of a full Unmerged Feature Stack (roadmap P23.5; spec: morning-report/write-the-night-summary,
    /// issue #448, OQ164, OQ177): names every Feature in U and each branch the gate did not find in mainline, from
    /// the event's own payload, says that merging the pull request by any method releases the next Feature and
    /// recommends no merge method, then gives the route out for a merge the gate cannot see (``MergeRouteOut``;
    /// OQ190 items 3 and 6, `#stack-full-skip`). At `unmerged_features_max = 1` with one Feature in U it reads as the
    /// predecessor line. It never claims a squash or rebase merge happened.
    private static func unmergedStackFullLine(
        features: [UnmergedStackEntry], unmergedFeaturesMax: Int, journal: JournalStore?
    ) -> String {
        let reason: String
        if unmergedFeaturesMax == 1, features.count == 1, let feature = features.first {
            let featureRef = stackEntryReference(feature, journal: journal)
            let completedOnBoard = ((try? journal?.feature(issueID: feature.featureIssueID))?.closedBy) == .completion
            let predecessor = completedOnBoard ? "\(featureRef), completed on the Board," : featureRef
            reason = "predecessor Feature \(predecessor) has not merged in "
                + feature.unmergedRepositories.joined(separator: ", ")
        } else {
            let refs = features.map { stackEntryReference($0, journal: journal) }.joined(separator: ", ")
            reason = "unmerged Feature stack reached unmerged_features_max "
                + "(\(features.count) unmerged Features: \(refs))"
        }
        let notFound = features.flatMap { feature in
            feature.unmergedRepositories.compactMap { repository in
                feature.branches[repository].map { "`\($0)` in \(repository)" }
            }
        }
        let branchSentence = notFound.isEmpty ? "" : " Not found in mainline: \(notFound.joined(separator: ", "))."
        return "Authoring was skipped: \(reason)." + branchSentence
            + " \(MergeRouteOut.nightCard) A quiet Night, not a failure."
    }

    /// A Feature of U as a Markdown link when the Journal has its issue URL, else its display identifier.
    private static func stackEntryReference(_ entry: UnmergedStackEntry, journal: JournalStore?) -> String {
        guard let journal, (try? journal.feature(issueID: entry.featureIssueID)) != nil else {
            return "`\(entry.identifier)`"
        }
        return renderFeatureReference(issueID: entry.featureIssueID, journal: journal)
    }

    /// The exception wording an authoring fault reads as (roadmap P9.10): a rolled-back Outbox group
    /// and a breakdown validation rejection say exactly the same thing — nothing is left on the
    /// board, so there is no Feature card to open and nothing to answer, and the author Act stood down
    /// without authoring. Never "halt"; never "A quiet Night, not a failure" (that phrase is reserved
    /// for a quiet skip, not a fault).
    private static func authoringFaultLine(feature name: String, reason: String) -> String {
        let trimmedReason = trimTrailingPeriod(reason)
        return """
        Authoring Feature `\(name)` failed: \(trimmedReason). Nothing is left on the board, so there is no \
        Feature card to open and nothing to answer; the author Act stood down without authoring. The \
        next author Act authors it afresh.
        """
    }

    private static func trimTrailingPeriod(_ string: String) -> String {
        if string.hasSuffix(".") {
            return String(string.dropLast())
        }
        return string
    }
}

extension NightCardMaintenance {
    /// One step of repairing a halted Feature (roadmap P22.5): accepted, deferred (and why) or invalid (and why).
    /// Never a halt of its own and never an authoring fault: a quiet Night.
    static func haltRepairLine(feature: String, step: String, detail: String?) -> String? {
        let why = detail.map { " (\($0))" } ?? ""
        switch step {
        case "requested":
            return "Feature `\(feature)` was moved to Todo for repair: it is validated, not authored again."
        case "deferred":
            return "Repair of Feature `\(feature)` was deferred\(why); it stays as the Operator set it."
        case "invalid":
            return """
                Repair of Feature `\(feature)` was not accepted\(why): it stays halted, with no Attempt and no \
                authoring fault.
                """
        case "accepted":
            return "Repair of Feature `\(feature)` was accepted: it continues as the same Feature\(why)."
        case "terminal":
            return "Halted Feature `\(feature)` was \(detail ?? "closed") on the Board: the halt resolved, no Cycle."
        default:
            return nil
        }
    }
}
