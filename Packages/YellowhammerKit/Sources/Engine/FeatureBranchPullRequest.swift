import Domain
import Foundation
import Journal
import Repositories

/// The land Act's real pull request seam (roadmap P10.4), the real ``PullRequestOpening``. Written
/// once per (Feature, repository): if the Journal already records a pull request it returns that
/// outcome and calls nothing — never updates, duplicates or reopens one. The title is the Project's
/// `pull_request_title` Message Template, rendered once with the body and never revised.
public struct FeatureBranchPullRequest: PullRequestOpening, Sendable {
    private let publication: any Publication
    private let slugResolver: GitHubRepositorySlugResolver
    private let clock: @Sendable () -> Date
    private let titleTemplate: MessageTemplate
    private let changeType: ChangeType
    private let projectID: String

    public init(
        publication: any Publication,
        slugResolver: GitHubRepositorySlugResolver = GitHubRepositorySlugResolver(),
        clock: @escaping @Sendable () -> Date = { Date() },
        titleTemplate: MessageTemplate = .default(.pullRequestTitle),
        changeType: ChangeType = .feat,
        projectID: String = ""
    ) {
        self.publication = publication
        self.slugResolver = slugResolver
        self.clock = clock
        self.titleTemplate = titleTemplate
        self.changeType = changeType
        self.projectID = projectID
    }

    public func open(
        _ context: LandActLaneContext, push: LanePushOutcome, mergeOutcome: MergeTestOutcome?
    ) async throws -> PullRequestOutcome {
        let journal = context.act.journal
        let repository = context.lane.repository

        if let recorded = try? journal.pullRequest(featureID: context.feature.id, repository: repository) {
            return PullRequestOutcome(opened: true, detail: recorded.url ?? "already open")
        }

        guard let repo = context.act.repositories?.workingRepos.first(where: { $0.name == repository }) else {
            return await fail(
                "no repository named \"\(repository)\" is configured", laneContext: context
            )
        }
        guard let branch = context.feature.branch else {
            return await fail("the Feature has no recorded Feature Branch for \"\(repository)\"", laneContext: context)
        }
        let path = (repo.path as NSString).expandingTildeInPath
        guard let slug = await slugResolver.resolve(path: path) else {
            return await fail(
                "the repository's origin remote could not be resolved to a GitHub owner/repository",
                laneContext: context
            )
        }

        // One board read serves the title, the key, the URL and the description (clause order).
        let featureObject = await BoardObjectLookup.find(
            ids: [context.feature.issueID], board: context.act.board
        )[context.feature.issueID]
        let (body, isPartial) = try await renderBody(
            context: context, mergeOutcome: mergeOutcome, featureObject: featureObject
        )
        let title = try renderTitle(
            context: context, featureObject: featureObject, branch: branch, isPartial: isPartial
        )
        let base = await resolveDefaultBranch(context: context, repo: repo, path: path)
        let draft = PullRequestDraft(
            owner: slug.owner, repository: slug.repository, head: branch.name, base: base,
            title: title, body: body
        )

        do {
            let receipt = try await publication.openPullRequest(draft)
            return await record(receipt, laneContext: context)
        } catch {
            return await failPublication(error, laneContext: context)
        }
    }

    /// The repository's default branch: the resolved mainline snapshot's, else the repository's own
    /// configured value, else resolved locally — mirrors ``FeatureBranchLanePush``'s own resolution.
    private func resolveDefaultBranch(context: LandActLaneContext, repo: Repo, path: String) async -> String {
        if let resolved = context.act.mainlines[repo.name] {
            return resolved.defaultBranch
        }
        if let configured = repo.defaultBranch {
            return configured
        }
        return await MainlineRefresher(git: GitRunner()).resolveDefaultBranch(for: repo, in: path)
    }

    private func record(_ receipt: PullRequestReceipt, laneContext: LandActLaneContext) async -> PullRequestOutcome {
        let journal = laneContext.act.journal
        let repository = laneContext.lane.repository
        switch receipt {
        case .opened(let url):
            _ = try? journal.recordPullRequest(
                featureID: laneContext.feature.id, repository: repository, url: url,
                nightID: laneContext.act.night.id, runID: laneContext.act.runID, now: clock()
            )
            await postLinks(url: url, laneContext: laneContext)
            return PullRequestOutcome(opened: true, detail: url)
        case .alreadyOpen:
            _ = try? journal.recordPullRequest(
                featureID: laneContext.feature.id, repository: repository, url: nil,
                nightID: laneContext.act.night.id, runID: laneContext.act.runID, now: clock()
            )
            return PullRequestOutcome(opened: true, detail: "already open")
        }
    }

    private func postLinks(url: String, laneContext: LandActLaneContext) async {
        guard let outbox = laneContext.act.outbox else { return }
        let repository = laneContext.lane.repository
        let cycleID = laneContext.cycleID
        let featureKey = "land:\(cycleID):\(repository):pull-request:\(laneContext.feature.issueID)"
        let featureIssue = BoardObjectID(rawValue: laneContext.feature.issueID)
        let featureWrite = OutboxWrite(
            key: featureKey,
            write: .attachLink(issue: featureIssue, url: url, title: "Pull Request")
        )
        _ = try? await outbox.post(featureWrite)

        for card in laneContext.lane.cards where card.state == .done {
            let key = "land:\(cycleID):\(repository):pull-request:\(card.issueID)"
            let write = OutboxWrite(
                key: key,
                write: .attachLink(issue: BoardObjectID(rawValue: card.issueID), url: url, title: "Pull Request")
            )
            _ = try? await outbox.post(write)
        }
    }

    private func fail(_ detail: String, laneContext: LandActLaneContext) async -> PullRequestOutcome {
        let repository = laneContext.lane.repository
        let body = "Opening a pull request for repository `\(repository)` did not complete: \(detail)."
        await postFailureComment(body: body, laneContext: laneContext)
        return PullRequestOutcome(opened: false, detail: detail)
    }

    private func failPublication(
        _ error: any Error, laneContext: LandActLaneContext
    ) async -> PullRequestOutcome {
        let repository = laneContext.lane.repository
        let detail: String
        if case .credentialsMissingOrInsufficient? = error as? PublicationError {
            detail = "GitHub credentials are missing or insufficient to open a pull request for `\(repository)`."
        } else {
            detail = "Opening a pull request for `\(repository)` did not complete: \(error)."
        }
        await postFailureComment(body: detail, laneContext: laneContext)
        return PullRequestOutcome(opened: false, detail: detail)
    }

    private func postFailureComment(body: String, laneContext: LandActLaneContext) async {
        guard let outbox = laneContext.act.outbox else { return }
        let key = "land:\(laneContext.cycleID):\(laneContext.lane.repository):pull-request-failed"
        let write = OutboxWrite(
            key: key,
            write: .createComment(issue: BoardObjectID(rawValue: laneContext.feature.issueID), body: body)
        )
        _ = try? await outbox.post(write)
    }

    // MARK: - Body assembly

    private func renderBody(
        context: LandActLaneContext, mergeOutcome: MergeTestOutcome?, featureObject: BoardObject?
    ) async throws -> (body: String, isPartial: Bool) {
        let journal = context.act.journal
        let repository = context.lane.repository
        let cards = try journal.cards(cycleID: context.cycleID)
        let pushed = try journal.pushedRepositories(featureID: context.feature.id)
        let noPullRequest = try journal.noPushedBranchRepositories(featureID: context.feature.id)
        let landings = try journal.landings(featureID: context.feature.id)

        let featureTitle = featureObject?.title ?? context.feature.issueID
        let featureIssueURL = featureObject?.url

        let bodyCards = try bodyCards(cards, journal: journal, cycleID: context.cycleID)
        let unmetClauses = try unmetClauses(cards, journal: journal)
        // Verification runs before this body is written (roadmap P10.5); when it recorded a report,
        // the body carries it and derives its unmet list from it. That list names issue ids, not
        // titles (VerificationReport carries no Card), so the renderer is handed this Cycle's own
        // issue id → display name lookup to resolve them (issue #161; spec:
        // landing/announce-a-partial-landing).
        let report = try journal.featureVerification(cycleID: context.cycleID).map(VerificationReport.init(record:))
        var cardTitles = Dictionary(uniqueKeysWithValues: cards.map { ($0.issueID, $0.displayTitle) })
        cardTitles[context.feature.issueID] = featureTitle

        let mergeVerdict = PullRequestBodyMergeVerdict(
            conflict: mergeOutcome?.conflict ?? false,
            untestable: mergeOutcome?.untestable ?? true,
            paths: mergeOutcome?.paths ?? [],
            mainlineRef: mergeOutcome?.mainlineRef,
            mainlineCommit: mergeOutcome?.mainlineCommit
        )

        let input = PullRequestBodyInput(
            featureTitle: featureTitle,
            featureIssueURL: featureIssueURL,
            nightID: context.act.night.id,
            nightTimestamp: context.act.night.nightStart.rawValue,
            repository: repository,
            pushedRepositoryCount: pushed.count,
            mergedCount: landings.count,
            cycleCards: bodyCards,
            mergeVerdict: mergeVerdict,
            unmetClauses: unmetClauses,
            verificationReport: report,
            cardTitles: cardTitles,
            noPullRequestRepositories: noPullRequest
        )
        return (PullRequestBody.render(input), input.isPartialLanding)
    }

    /// One rendering input per Card, joining the Journal's Attempt/Round summary and the lane-hole and
    /// carried-forward flags onto each `CardRecord`.
    private func bodyCards(
        _ cards: [CardRecord], journal: JournalStore, cycleID: Int64
    ) throws -> [PullRequestBodyCard] {
        // laneHoles (P8.9) is already exactly "Blocked or Waiting on You" within this Cycle — the same
        // vocabulary the Partial Landing announcement names a hole by; reused rather than reimplemented.
        let holeIDs = Set(try journal.laneHoles(cycleID: cycleID).map(\.id))
        return try cards.map { card in
            let summary = try journal.attemptSummary(cardID: card.id)
            return PullRequestBodyCard(
                title: card.displayTitle,
                repository: card.repository,
                state: card.state,
                routeSummary: summary.routeSummary,
                checkSummary: summary.checkSummary,
                roundCount: summary.roundCount,
                blockReason: card.blockReason,
                waitingReason: card.waitingReason,
                isLaneHole: holeIDs.contains(card.id),
                // The story ("Announce a Partial Landing") names only a Card still Waiting on You at
                // landing as "carried forward" — it alone is auto-Blocked and awaits Adoption. A
                // Blocked Card is not renamed; it was already Blocked.
                carriedForward: card.state == .waitingOnYou
            )
        }
    }

    /// Definition of Done clauses of the incomplete (Blocked or Waiting on You) Cards, quoted with
    /// their Spec Citation and marked unmet. This is the set known from Card state alone; when
    /// Verification recorded a report (P10.5) the body derives its list from that report instead.
    private func unmetClauses(
        _ cards: [CardRecord], journal: JournalStore
    ) throws -> [PullRequestBodyUnmetClause] {
        var unmetClauses: [PullRequestBodyUnmetClause] = []
        for card in cards where card.state == .blocked || card.state == .waitingOnYou {
            for clause in try journal.clauses(issueID: card.issueID) {
                let text = clause.invalidated
                    ? "\(clause.text) (invalidated: \(clause.invalidatedCause ?? "unspecified"))"
                    : clause.text
                unmetClauses.append(
                    PullRequestBodyUnmetClause(cardTitle: card.displayTitle, text: text, citation: clause.locationID)
                )
            }
        }
        return unmetClauses
    }
}

// MARK: - Title

extension FeatureBranchPullRequest {
    /// The Project's `pull_request_title` Message Template, rendered once with the body. The primary
    /// epic comes from the Feature-level clauses in the order of the description as it stands now.
    private func renderTitle(
        context: LandActLaneContext, featureObject: BoardObject?, branch: FeatureBranch, isPartial: Bool
    ) throws -> String {
        let featureClauses = try context.act.journal.clauses(issueID: context.feature.issueID)
        let primaryEpic = PullRequestTitle.primaryEpic(
            citations: ClauseOrder.inClauseOrder(featureClauses, description: featureObject?.description)
                .map { SpecCitation($0.locationID) }
        )
        return PullRequestTitle.render(
            template: titleTemplate, changeType: changeType,
            inputs: PullRequestTitle.Inputs(
                featureTitle: featureObject?.title ?? context.feature.issueID,
                featureKey: featureObject?.key ?? "",
                repository: context.lane.repository,
                branch: branch.name,
                projectID: projectID,
                isPartialLanding: isPartial,
                primaryEpic: primaryEpic
            )
        )
    }
}
