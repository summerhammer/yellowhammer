import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// OQ197 (verification/verify-a-feature-clause-by-clause#report-limitation; ruling 2026-10-30, item 1): when the
// Feature touches more than one repository, the limitation stated beside the Verification report adds that each
// Check ran in its own repository. For one repository the text does not change. Both surfaces: the Feature
// Card's Managed Block and the pull request body, Complete and Partial Landing alike.

private func limitationClause() -> ClauseVerificationRecord {
    ClauseVerificationRecord(
        issueID: "BACK-1", cid: "c1", level: "card", text: "Returns 404 for a missing id.", locationID: "epic/story",
        citationProvenance: "machine-found", verdict: .met, whatWasChecked: "read the handler",
        interpretation: "the id is the path parameter", judgedBy: .agent
    )
}

private func limitationBodyInput(report: VerificationReport, partial: Bool) -> PullRequestBodyInput {
    let done = PullRequestBodyCard(
        title: "BACK-1", repository: "backend", state: .done, routeSummary: "r", checkSummary: "c", roundCount: 1
    )
    let blocked = PullRequestBodyCard(
        title: "BACK-2", repository: "backend", state: .blocked, routeSummary: "r", checkSummary: "c", roundCount: 1,
        blockReason: "route failure"
    )
    return PullRequestBodyInput(
        featureTitle: "Widgets", featureIssueURL: nil, nightID: 3, nightTimestamp: "2026-09-16",
        repository: "backend", pushedRepositoryCount: 2, mergedCount: 0,
        cycleCards: partial ? [done, blocked] : [done],
        mergeVerdict: PullRequestBodyMergeVerdict(conflict: false, untestable: true), unmetClauses: [],
        verificationReport: report
    )
}

/// How many times `sentence` occurs in `text`.
private func occurrences(of sentence: String, in text: String) -> Int {
    text.components(separatedBy: sentence).count - 1
}

@Suite("Verification limitation: separate Checks are named for a Feature touching several repositories (OQ197)")
struct VerificationLimitationTests {
    @Test("The sentence is the ruling's, 171 characters")
    func sentenceIsTheRulings() {
        #expect(VerificationReport.separateChecksSentence.count == 171)
        #expect(VerificationReport.separateChecksSentence.hasPrefix("Each Check ran in its own repository; "))
        #expect(VerificationReport.separateChecksSentence.hasSuffix("not evidence that they were tested together."))
    }

    @Test("One repository: the limitation is unchanged on the Managed Block and in every body")
    func oneRepositoryUnchanged() throws {
        let report = VerificationReport(clauses: [limitationClause()], touchedRepositoryCount: 1)
        #expect(report.limitationStatement == VerificationReport.limitation)

        let lastLine = try #require(report.managedBlockLines().split(separator: "\n").last)
        #expect(lastLine == VerificationReport.managedBlockPrefix + VerificationReport.limitation)
        for partial in [false, true] {
            let input = limitationBodyInput(report: report, partial: partial)
            try #require(input.isPartialLanding == partial)
            let body = PullRequestBody.render(input)
            #expect(body.contains(VerificationReport.limitation))
            #expect(!body.contains("Each Check ran in its own repository"))
        }
        #expect(!report.markdownSection().contains("Each Check ran in its own repository"))
    }

    @Test("Two repositories: the sentence follows the limitation once, on the Managed Block and in every body")
    func twoRepositoriesAddTheSentence() throws {
        let report = VerificationReport(clauses: [limitationClause()], touchedRepositoryCount: 2)
        let expected = VerificationReport.limitation + " " + VerificationReport.separateChecksSentence
        #expect(report.limitationStatement == expected)

        let block = report.managedBlockLines()
        let lastLine = try #require(block.split(separator: "\n").last)
        #expect(lastLine == VerificationReport.managedBlockPrefix + expected)
        #expect(occurrences(of: VerificationReport.separateChecksSentence, in: block) == 1)
        for partial in [false, true] {
            let input = limitationBodyInput(report: report, partial: partial)
            try #require(input.isPartialLanding == partial)
            let body = PullRequestBody.render(input)
            #expect(body.contains(expected))
            #expect(occurrences(of: VerificationReport.separateChecksSentence, in: body) == 1)
        }
    }

    @Test("A record built with no count reads as one repository, and three repositories read as several")
    func countThresholds() {
        let record = FeatureVerificationRecord(
            id: 1, featureID: 1, cycleID: 1, route: nil, nightID: 1, runID: RunID(),
            verifiedAt: Date(timeIntervalSince1970: 0), clauses: [limitationClause()], judgedCheckouts: []
        )
        #expect(VerificationReport(record: record).limitationStatement == VerificationReport.limitation)
        #expect(
            VerificationReport(record: record, touchedRepositoryCount: 3).limitationStatement
                .hasSuffix(VerificationReport.separateChecksSentence)
        )
    }

    @Test("The return comment on the Feature Card states the same limitation as the report beside it")
    func returnCommentFollows() {
        let one = FeatureReturnComment(clauses: [limitationClause()], pullRequests: [:]).body()
        #expect(one.hasSuffix(VerificationReport.limitation))
        let two = FeatureReturnComment(clauses: [limitationClause()], pullRequests: [:], touchedRepositoryCount: 2)
            .body()
        #expect(two.hasSuffix(VerificationReport.limitation + " " + VerificationReport.separateChecksSentence))
        #expect(occurrences(of: VerificationReport.separateChecksSentence, in: two) == 1)
    }
}

// MARK: - Through the land Act

/// The Verification report the land Act queued onto the Feature Card's Managed Block.
private func queuedReport(_ world: OQ191LandWorld) throws -> String {
    let reports = try world.env.journal.outboxEntries(forIssue: "FEAT-1")
        .filter { $0.payload.contains(VerificationReport.managedBlockPrefix) }
    return try #require(reports.last?.payload)
}

/// The body of the pull request opened for `repository`.
private func openedBody(_ world: OQ191LandWorld, _ repository: String) async throws -> String {
    try #require(await world.publication.calls.last { $0.repository == repository }?.body)
}

@Suite("Verification limitation through the land Act (OQ197)", .serialized)
struct VerificationLimitationLandActTests {
    @Test("A Feature touching two repositories gets the sentence on its Managed Block and in every pull request body")
    func twoTouchedRepositories() async throws {
        let world = try await OQ191LandWorld.make()
        try #require(try world.env.journal.touchedRepositories(featureID: world.feature.id).count == 2)
        let firing = await world.fire()
        try #require(firing.error == nil)

        let block = try queuedReport(world)
        #expect(occurrences(of: VerificationReport.separateChecksSentence, in: block) == 1)
        for repository in ["backend", "mobile"] {
            let body = try await openedBody(world, repository)
            #expect(body.contains(VerificationReport.limitation + " " + VerificationReport.separateChecksSentence))
            #expect(occurrences(of: VerificationReport.separateChecksSentence, in: body) == 1)
        }
    }

    @Test("A Feature touching one repository keeps the limitation unchanged on both surfaces")
    func oneTouchedRepository() async throws {
        let world = try await OQ191LandWorld.make(withMobile: false)
        try #require(try world.env.journal.touchedRepositories(featureID: world.feature.id).count == 1)
        let firing = await world.fire()
        try #require(firing.error == nil)

        let block = try queuedReport(world)
        #expect(block.contains("auditable, not sound"))
        #expect(!block.contains("Each Check ran in its own repository"))
        let body = try await openedBody(world, "backend")
        #expect(body.contains(VerificationReport.limitation))
        #expect(!body.contains("Each Check ran in its own repository"))
    }
}
