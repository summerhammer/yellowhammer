import Domain
@testable import Engine
@testable import EngineCommand
import Foundation
@testable import Journal
import Testing

// Acceptance criteria for issue #411:
// - Night Card authoring lines render the predecessor Feature by identifier.
// - A Refusal or halt line does not contain "quiet Night".
// - No rendered board copy embeds a 36-character UUID where an identifier exists.

@Suite("Night Card authoring copy (issue #411)")
struct NightCardAuthoringCopyTests {
    private func uuidRegex() throws -> Regex<AnyRegexOutput> {
        try Regex(#"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#)
    }

    @Test("Predecessor Feature is rendered by identifier and Markdown link when recorded")
    func predecessorFeatureRenderedByIdentifierAndLink() throws {
        let pattern = try uuidRegex()
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let featureUUID = "114fe249-d329-47bf-b5f5-ad041a55cbd3"
        let displayID = "YLH-319"
        let url = "https://linear.app/team/issue/YLH-319"

        try journal.write { db in
            try db.execute(
                sql: """
                INSERT INTO feature (issue_id, issue_id_for_display, issue_url, state, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [featureUUID, displayID, url, "selected", JournalStore.timestamp(Date())]
            )
        }

        let indeterminate = JournalEvent.authoringPredecessorIndeterminate(
            featureIssueID: featureUUID, repositories: ["yellowhammer"]
        )
        let indeterminateLine = try #require(NightCardMaintenance.authoringLine(for: indeterminate, journal: journal))
        #expect(!indeterminateLine.contains(featureUUID))
        #expect(indeterminateLine.contains("[\(displayID)](\(url))"))
        #expect(indeterminateLine.contains("A quiet Night, not a failure."))

        let notLanded = stackFullSkip(
            featureUUID, ["yellowhammer"], identifier: displayID, branches: ["yellowhammer": "yh-ylh-319"]
        )
        let notLandedLine = try #require(NightCardMaintenance.authoringLine(for: notLanded, journal: journal))
        #expect(!notLandedLine.contains(featureUUID))
        #expect(notLandedLine.contains("[\(displayID)](\(url))"))
        #expect(notLandedLine.contains("A quiet Night, not a failure."))

        let skippedInFlight = JournalEvent.authoringSkippedFeatureInFlight(
            featureIssueID: featureUUID
        )
        let skippedLine = try #require(NightCardMaintenance.authoringLine(for: skippedInFlight, journal: journal))
        #expect(!skippedLine.contains(featureUUID))
        #expect(skippedLine.contains("[\(displayID)](\(url))"))
        #expect(skippedLine.contains("A quiet Night, not a failure."))

        #expect(!indeterminateLine.contains(pattern))
        #expect(!notLandedLine.contains(pattern))
        #expect(!skippedLine.contains(pattern))
    }

    @Test("Predecessor Feature falls back to backticked identifier when URL is not recorded")
    func predecessorFeatureWithoutURL() throws {
        let pattern = try uuidRegex()
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let featureUUID = "224fe249-d329-47bf-b5f5-ad041a55cbd3"
        let displayID = "YLH-320"

        try journal.write { db in
            try db.execute(
                sql: """
                INSERT INTO feature (issue_id, issue_id_for_display, state, created_at)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [featureUUID, displayID, "selected", JournalStore.timestamp(Date())]
            )
        }

        let event = JournalEvent.authoringPredecessorIndeterminate(
            featureIssueID: featureUUID, repositories: ["yellowhammer"]
        )
        let line = try #require(NightCardMaintenance.authoringLine(for: event, journal: journal))
        #expect(!line.contains(featureUUID))
        #expect(line.contains("`\(displayID)`"))
        #expect(!line.contains(pattern))
    }

    @Test("Refusal and halt lines do not contain 'quiet Night' and name Operator turn")
    func refusalAndHaltLinesNameOperatorTurn() throws {
        let halt = JournalEvent.featureAuthoringHalted(
            name: "FEAT-1", reasonKind: "no-backward-compatible-seam", detail: "api"
        )
        let haltLine = try #require(NightCardMaintenance.authoringLine(for: halt))
        #expect(!haltLine.lowercased().contains("quiet night"))
        #expect(haltLine.contains("Waiting on You"))
        #expect(haltLine.contains("Operator"))

        let refusalOpened = JournalEvent.refusalOpened(
            feature: "FEAT-1", consecutiveRefusals: 1, uncitableClauses: "c1", reselectionDepth: 2
        )
        let refusalOpenedLine = try #require(NightCardMaintenance.authoringLine(for: refusalOpened))
        #expect(!refusalOpenedLine.lowercased().contains("quiet night"))
        #expect(refusalOpenedLine.contains("Refusal"))
        #expect(refusalOpenedLine.contains("Waiting on You"))
        #expect(refusalOpenedLine.contains("Operator"))

        let refusalRepeated = JournalEvent.refusalRepeated(
            feature: "FEAT-1", consecutiveRefusals: 2, uncitableClauses: "c1", reselectionDepth: 2
        )
        let refusalRepeatedLine = try #require(NightCardMaintenance.authoringLine(for: refusalRepeated))
        #expect(!refusalRepeatedLine.lowercased().contains("quiet night"))
        #expect(refusalRepeatedLine.contains("Refusal"))
        #expect(refusalRepeatedLine.contains("Waiting on You"))
        #expect(refusalRepeatedLine.contains("Operator"))
    }

    @Test("Genuine skips keep 'A quiet Night, not a failure.'")
    func genuineSkipsKeepQuietNight() throws {
        let noWork = JournalEvent.authoringNoWorkAvailable
        let noWorkLine = try #require(NightCardMaintenance.authoringLine(for: noWork))
        #expect(noWorkLine.contains("A quiet Night, not a failure."))

        let inFlight = JournalEvent.authoringSkippedFeatureInFlight(featureIssueID: "FEAT-1")
        let inFlightLine = try #require(NightCardMaintenance.authoringLine(for: inFlight))
        #expect(inFlightLine.contains("A quiet Night, not a failure."))

        let notLanded = stackFullSkip("FEAT-1", ["backend"])
        let notLandedLine = try #require(NightCardMaintenance.authoringLine(for: notLanded))
        #expect(notLandedLine.contains("A quiet Night, not a failure."))

        let indeterminate = JournalEvent.authoringPredecessorIndeterminate(
            featureIssueID: "FEAT-1", repositories: ["backend"]
        )
        let indeterminateLine = try #require(NightCardMaintenance.authoringLine(for: indeterminate))
        #expect(indeterminateLine.contains("A quiet Night, not a failure."))
    }

    @Test("At max 1 the skip reads as the predecessor line, naming each Feature Branch and the route out (#448)")
    func predecessorLineNamesBranchesAndMergeCommit() throws {
        let fixture = try NightCardJournalFixture()
        let journal = try fixture.open()
        let featureUUID = "334fe249-d329-47bf-b5f5-ad041a55cbd3"
        try journal.write { db in
            try db.execute(
                sql: """
                INSERT INTO feature (issue_id, issue_id_for_display, state, created_at)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [featureUUID, "YLH-321", "selected", JournalStore.timestamp(Date())]
            )
        }

        let event = stackFullSkip(
            featureUUID, ["web", "backend"], identifier: "YLH-321",
            branches: ["web": "yh-feature-web", "backend": "yh-feature-backend"]
        )
        let line = try #require(NightCardMaintenance.authoringLine(for: event, journal: journal))
        #expect(line.hasPrefix("Authoring was skipped: predecessor Feature `YLH-321` has not merged in web, backend."))
        #expect(line.contains("Not found in mainline: `yh-feature-web` in web, `yh-feature-backend` in backend."))
        #expect(line.contains(MergeCommitRecommendation.shared))
        #expect(line.contains("(`git merge -s ours`) with a merge commit opens this gate."))
        #expect(!line.contains("An edit to the same lines"))
        #expect(!line.contains("unmerged_features_max"))
        #expect(line.hasSuffix("A quiet Night, not a failure."))
    }

    @Test("The skip line without a Journal names the Feature by its identifier and keeps the branches")
    func predecessorLineWithoutJournal() throws {
        let event = stackFullSkip("FEAT-1", ["backend"], identifier: "YLH-1", branches: ["backend": "yh-ylh-1"])
        let line = try #require(NightCardMaintenance.authoringLine(for: event))
        #expect(line.contains("predecessor Feature `YLH-1` has not merged in backend."))
        #expect(line.contains("Not found in mainline: `yh-ylh-1` in backend."))
        #expect(line.contains(MergeCommitRecommendation.shared))
        #expect(line.hasSuffix("A quiet Night, not a failure."))
    }

    @Test("Above max 1 the skip line names the stack, every Feature, and each unmerged branch, verbatim")
    func stackFullLineNamesEveryFeatureAndBranch() throws {
        let features = [
            UnmergedStackEntry(
                featureIssueID: "F1", identifier: "YLH-1", unmergedRepositories: ["backend", "mobile"],
                branches: ["backend": "yh-ylh-1", "mobile": "yh-ylh-1-mobile"]
            ),
            UnmergedStackEntry(
                featureIssueID: "F2", identifier: "YLH-2", unmergedRepositories: ["backend"],
                branches: ["backend": "yh-ylh-2"]
            ),
            UnmergedStackEntry(
                featureIssueID: "F3", identifier: "YLH-3", unmergedRepositories: ["mobile"],
                branches: ["mobile": "yh-ylh-3"]
            )
        ]
        let line = try #require(NightCardMaintenance.authoringLine(
            for: .authoringSkippedUnmergedStackFull(features: features, unmergedFeaturesMax: 3)
        ))
        #expect(line == "Authoring was skipped: unmerged Feature stack reached unmerged_features_max "
            + "(3 unmerged Features: `YLH-1`, `YLH-2`, `YLH-3`). Not found in mainline: `yh-ylh-1` in backend, "
            + "`yh-ylh-1-mobile` in mobile, `yh-ylh-2` in backend, `yh-ylh-3` in mobile. "
            + MergeCommitRecommendation.shared
            + " If mainline already has the changes, a content-free merge of the Feature Branch (`git merge -s ours`) "
            + "with a merge commit opens this gate. A quiet Night, not a failure.")
    }

    @Test("At max 1 with more than one Feature in U (the bound lowered), the line names the stack, not a predecessor")
    func loweredBoundNamesTheStack() throws {
        let entry = { (id: String) in
            UnmergedStackEntry(featureIssueID: id, identifier: id, unmergedRepositories: ["backend"], branches: [:])
        }
        let line = try #require(NightCardMaintenance.authoringLine(
            for: .authoringSkippedUnmergedStackFull(features: [entry("F1"), entry("F2")], unmergedFeaturesMax: 1)
        ))
        #expect(line.contains("reached unmerged_features_max (2 unmerged Features: `F1`, `F2`)."))
        #expect(!line.contains("predecessor Feature"))
        #expect(!line.contains("Not found in mainline"))
    }

    @Test("The merge-commit recommendation is word for word the same in both bodies and the Night Card line")
    func recommendationIsSharedAcrossSurfaces() throws {
        let sentences = [
            "Merging with **Create a merge commit** always releases the next Feature.",
            "Squash and merge or Rebase and merge works too, but it is recognised only while mainline "
                + "still shows this branch's changes."
        ]
        #expect(MergeCommitRecommendation.shared == sentences.joined(separator: " "))

        let done = PullRequestBodyCard(
            title: "BACK-1", repository: "backend", state: .done, routeSummary: "r", checkSummary: "c", roundCount: 1
        )
        let blocked = PullRequestBodyCard(
            title: "BACK-2", repository: "backend", state: .blocked, routeSummary: "r", checkSummary: "c",
            roundCount: 1, blockReason: "route failure"
        )
        func body(_ cards: [PullRequestBodyCard]) -> String {
            PullRequestBody.render(PullRequestBodyInput(
                featureTitle: "Widgets", featureIssueURL: nil, nightID: 3, nightTimestamp: "2026-09-16",
                repository: "backend", pushedRepositoryCount: 1, mergedCount: 0, cycleCards: cards,
                mergeVerdict: PullRequestBodyMergeVerdict(conflict: false, untestable: true), unmetClauses: []
            ))
        }
        let complete = body([done])
        let partial = body([done, blocked])
        let card = try #require(NightCardMaintenance.authoringLine(
            for: stackFullSkip("FEAT-1", ["backend"])
        ))

        let editSentence =
            "An edit to the same lines before the next Night holds the next Feature back."
        for surface in [complete, partial, card] {
            for sentence in sentences { #expect(surface.contains(sentence)) }
        }
        for pullRequestBody in [complete, partial] {
            #expect(pullRequestBody.contains(editSentence))
            #expect(!pullRequestBody.contains("git merge -s ours"))
        }
        #expect(complete.contains(
            PullRequestBody.releaseSentence + "\n" + MergeCommitRecommendation.shared + " " + editSentence
        ))
        #expect(partial.contains(
            "Merging satisfies the landing gate for the repositories it reached and releases the next Feature."
                + "\n" + MergeCommitRecommendation.shared + " " + editSentence
        ))
        #expect(!card.contains(editSentence))
    }

    @Test("No surface says a squash or rebase merge stalls the next Feature, or that one happened")
    func oldStallPhrasesAppearNowhere() throws {
        let done = PullRequestBodyCard(
            title: "BACK-1", repository: "backend", state: .done, routeSummary: "r", checkSummary: "c", roundCount: 1
        )
        let blocked = PullRequestBodyCard(
            title: "BACK-2", repository: "backend", state: .blocked, routeSummary: "r", checkSummary: "c",
            roundCount: 1, blockReason: "route failure"
        )
        let surfaces = [[done], [done, blocked]].map { cards in
            PullRequestBody.render(PullRequestBodyInput(
                featureTitle: "Widgets", featureIssueURL: nil, nightID: 3, nightTimestamp: "2026-09-16",
                repository: "backend", pushedRepositoryCount: 1, mergedCount: 0, cycleCards: cards,
                mergeVerdict: PullRequestBodyMergeVerdict(conflict: false, untestable: true), unmetClauses: []
            ))
        } + [try #require(NightCardMaintenance.authoringLine(
            for: stackFullSkip("FEAT-1", ["backend"])
        ))]
        let banned = [
            "never becomes an ancestor", "never authored", "writes new commits", "Not an ancestor of mainline",
            "has not landed", "was squash", "was rebase", "was merged with Squash"
        ]
        for surface in surfaces {
            for phrase in banned { #expect(!surface.contains(phrase), "found: \(phrase)") }
        }
    }

    @Test("Authoring fault line reads 'Nothing is left on the board' and trims a trailing period (issue #489)")
    func authoringFaultLineReadsNothingIsLeftOnTheBoard() throws {
        let failedWithPeriod = JournalEvent.featureAuthoringFailed(
            name: "Show pending Proposals", groupKey: "grp", reason: "board write failed."
        )
        let lineWithPeriod = try #require(NightCardMaintenance.authoringLine(for: failedWithPeriod))
        #expect(lineWithPeriod.contains("failed: board write failed. Nothing is left on the board"))
        #expect(!lineWithPeriod.contains(".."))
        #expect(!lineWithPeriod.contains("Nothing was written to the board"))

        let failedWithoutPeriod = JournalEvent.featureAuthoringFailed(
            name: "Show pending Proposals", groupKey: "grp", reason: "board write failed"
        )
        let lineWithoutPeriod = try #require(NightCardMaintenance.authoringLine(for: failedWithoutPeriod))
        #expect(lineWithoutPeriod.contains("failed: board write failed. Nothing is left on the board"))
        #expect(!lineWithoutPeriod.contains(".."))

        let breakdownRejected = JournalEvent.featureBreakdownRejected(
            name: "Show pending Proposals", reason: "permission denied."
        )
        let breakdownLine = try #require(NightCardMaintenance.authoringLine(for: breakdownRejected))
        #expect(breakdownLine.contains("failed: permission denied. Nothing is left on the board"))
        #expect(!breakdownLine.contains(".."))
    }

    @Test("Feature selection failure trims trailing period (issue #489)")
    func failureLinesEndingInPeriodRenderSinglePeriod() throws {
        let selectionWithPeriod = JournalEvent.featureSelectionFailed(reason: "no Route left.")
        let selectionLineWithPeriod = try #require(NightCardMaintenance.authoringLine(for: selectionWithPeriod))
        #expect(selectionLineWithPeriod.contains("failed: no Route left. Nothing was written to the board"))
        #expect(!selectionLineWithPeriod.contains(".."))

        let selectionWithoutPeriod = JournalEvent.featureSelectionFailed(reason: "no Route left")
        let selectionLineWithoutPeriod = try #require(NightCardMaintenance.authoringLine(for: selectionWithoutPeriod))
        #expect(selectionLineWithoutPeriod.contains("failed: no Route left. Nothing was written to the board"))
        #expect(!selectionLineWithoutPeriod.contains(".."))
    }
}
