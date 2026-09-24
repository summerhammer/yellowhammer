import CryptoKit
import Domain
import Engine
import Foundation
import Testing

// P7.1: result schema and instruction contract

@Test("Every valid architect and worker rehearsal fixture decodes to the expected outcome")
func architectAndWorkerFixturesDecodeToExpectedOutcome() throws {
    let architectPlanned = try RehearsalResultFixture.architectPlanned.decode()
    guard case .architect(let result) = architectPlanned,
        case .planned(let plan, let affectedPaths) = result.outcome
    else {
        Issue.record("expected architect .planned")
        return
    }
    #expect(!plan.isEmpty)
    #expect(!affectedPaths.isEmpty)

    let architectFailed = try RehearsalResultFixture.architectFailed.decode()
    guard case .architect(let result) = architectFailed, case .failed(let reason) = result.outcome else {
        Issue.record("expected architect .failed")
        return
    }
    #expect(!reason.isEmpty)

    let workerCompleted = try RehearsalResultFixture.workerCompleted.decode()
    guard case .worker(let result) = workerCompleted, case .completed(let commit, let summary) = result.outcome else {
        Issue.record("expected worker .completed")
        return
    }
    #expect(commit.count == 40)
    #expect(!summary.isEmpty)

    let workerQuestion = try RehearsalResultFixture.workerQuestion.decode()
    guard case .worker(let result) = workerQuestion, case .question(let question) = result.outcome else {
        Issue.record("expected worker .question")
        return
    }
    #expect(!question.isEmpty)

    let workerFailed = try RehearsalResultFixture.workerFailed.decode()
    guard case .worker(let result) = workerFailed, case .failed(let reason) = result.outcome else {
        Issue.record("expected worker .failed")
        return
    }
    #expect(!reason.isEmpty)
}

@Test("Every valid reviewer rehearsal fixture decodes to the expected outcome")
func reviewerFixturesDecodeToExpectedOutcome() throws {
    let reviewerApproved = try RehearsalResultFixture.reviewerApproved.decode()
    guard case .reviewer(let result) = reviewerApproved,
        case .approved(let judgedCommit, let summary) = result.outcome
    else {
        Issue.record("expected reviewer .approved")
        return
    }
    #expect(judgedCommit.count == 40)
    #expect(!summary.isEmpty)

    let reviewerChangesRequested = try RehearsalResultFixture.reviewerChangesRequested.decode()
    guard
        case .reviewer(let result) = reviewerChangesRequested,
        case .changesRequested(_, _, let requestedChanges) = result.outcome
    else {
        Issue.record("expected reviewer .changesRequested")
        return
    }
    #expect(!requestedChanges.isEmpty)
}

@Test("An empty result file fails validation as .empty")
func emptyResultFileFailsValidation() throws {
    #expect(throws: ResultFileError.empty) {
        try RehearsalResultFixture.workerEmpty.decode()
    }
}

@Test("A truncated result file fails validation as .malformedJSON")
func malformedResultFileFailsValidation() throws {
    do {
        _ = try RehearsalResultFixture.workerMalformed.decode()
        Issue.record("expected decoding to throw")
    } catch let error as ResultFileError {
        guard case .malformedJSON = error else {
            Issue.record("expected .malformedJSON, got \(error)")
            return
        }
    }
}

@Test("A worker file decoded expecting reviewer fails as .passMismatch")
func passMismatchFailsValidation() throws {
    let data = RehearsalResultFixture.workerCompleted.data()
    #expect(throws: ResultFileError.passMismatch(expected: .reviewer, found: .worker)) {
        try ResultFile.decode(data, expecting: .reviewer)
    }
}

@Test("An unsupported schema version fails as .unsupportedVersion")
func unsupportedVersionFailsValidation() throws {
    let json = """
        {"schema": "yellowhammer.result.worker", "version": 2, "outcome": "completed", \
        "commit": "\(String(repeating: "a", count: 40))", "summary": "x"}
        """
    let data = try #require(json.data(using: .utf8))
    #expect(throws: ResultFileError.unsupportedVersion(2)) {
        try ResultFile.decode(data, expecting: .worker)
    }
}

@Test("changes_requested with empty requested_changes fails as .invalid")
func changesRequestedWithEmptyRequestedChangesFailsValidation() throws {
    let json = """
        {"schema": "yellowhammer.result.reviewer", "version": 1, "verdict": "changes_requested", \
        "judged_commit": "\(String(repeating: "a", count: 40))", "summary": "x", "requested_changes": []}
        """
    let data = try #require(json.data(using: .utf8))
    #expect(throws: (any Error).self) {
        try ResultFile.decode(data, expecting: .reviewer)
    }
}

@Test("approved with non-empty requested_changes fails as .invalid")
func approvedWithRequestedChangesFailsValidation() throws {
    let json = """
        {"schema": "yellowhammer.result.reviewer", "version": 1, "verdict": "approved", \
        "judged_commit": "\(String(repeating: "a", count: 40))", "summary": "x", \
        "requested_changes": ["fix it"]}
        """
    let data = try #require(json.data(using: .utf8))
    #expect(throws: (any Error).self) {
        try ResultFile.decode(data, expecting: .reviewer)
    }
}

@Test("A 39-character commit fails as .invalid")
func shortCommitFailsValidation() throws {
    let json = """
        {"schema": "yellowhammer.result.worker", "version": 1, "outcome": "completed", \
        "commit": "\(String(repeating: "a", count: 39))", "summary": "x"}
        """
    let data = try #require(json.data(using: .utf8))
    #expect(throws: (any Error).self) {
        try ResultFile.decode(data, expecting: .worker)
    }
}

@Test("Whitespace-only data fails as .empty")
func whitespaceOnlyFailsValidation() throws {
    let data = Data("   \n\t  ".utf8)
    #expect(throws: ResultFileError.empty) {
        try ResultFile.decode(data, expecting: .worker)
    }
}

@Test("An unknown outcome fails as .invalid")
func unknownOutcomeFailsValidation() throws {
    let json = """
        {"schema": "yellowhammer.result.worker", "version": 1, "outcome": "sleeping"}
        """
    let data = try #require(json.data(using: .utf8))
    #expect(throws: (any Error).self) {
        try ResultFile.decode(data, expecting: .worker)
    }
}

@Test("An unknown schema fails as .unknownSchema")
func unknownSchemaFailsValidation() throws {
    let json = """
        {"schema": "yellowhammer.result.mystery", "version": 1, "outcome": "completed"}
        """
    let data = try #require(json.data(using: .utf8))
    #expect(throws: (any Error).self) {
        try ResultFile.decode(data, expecting: .worker)
    }
}

// P15.3 (live rehearsal fix): each fixture's bytes are embedded in the binary as a Swift string literal
// (`RehearsalResultFixtures+Contents.swift`) — there is no resource bundle to resolve any more, so what
// used to be "resolves to an existing file" is now "the embedded bytes match, exactly" (a SHA-256 pin
// catches an accidental edit of a literal, byte-exact, including whitespace and the trailing newline).
private let expectedFixtureDigests: [RehearsalResultFixture: String] = [
    .architectPlanned: "403c590d8e581d66c6c02085755944f6fed363940dc36d498f73a90796b59f98",
    .architectFailed: "db8cef6b8cf5ac5692f1873625da58d59573124409077df7e642898568b4d48c",
    .workerCompleted: "501535b7c886b181028baf1a99f93af3c87a5ea3cc487ec599e6ab3da1511f0c",
    .workerQuestion: "37bd66514d4169361524b0470bd4503a5c152847d72ddf2de93f1ee43b3eb5c4",
    .workerFailed: "f2e00e9c19879f1b26dcf8418e3e6f06e48e64a790389c4de013b8dab7bb28d8",
    .reviewerApproved: "21ad6ca67ab73188e3bf2a10d7e579ac482cb7e65d20798740560e013d9d8ca3",
    .reviewerChangesRequested: "f6d0fcb2a5ea96a59d1058adec65ee36457aee747b9ad8db4615438daf91c3b7",
    .workerEmpty: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    .workerMalformed: "b874c415fe379722db7186cb906e58e83de07da119ad63d598471a705aa1aa74",
    .selectionSelected: "a1da06ea4e4fc901ff8a00dd58b5bcb5f33e62e93fb7981e4b20a5a5d7bf48bd",
    .selectionNoSelectableFeature: "1b0ca854669f8da9d61661c90d39a68153933a711a50fde89bc66f176e5c9cfa",
    .selectionFailed: "9358f2e2e905ba258e0c45ef7327d92d1637acce30ce78ed5c528337558a3630",
    .breakdownDrafted: "92e63d7feb6c07f8adc724f7c873f1939956913e5399cdd855e928d07f3092a5",
    .selectionSelectedWithContract: "5f4b186a8fcfe01056c17a02ceaac1267c6c548bef654e88239b966292e0cefa",
    .breakdownDraftedWithContract: "fac62e5f3254c8309b82a3482e2ce69a04a8ee2d95198084f82da26b8bd94329",
    .selectionSelectedAdopting: "db729b4453a7278d0e48f12f6defc0c1535e95009cb3690b3ada65c52f171633",
    .selectionSelectedThreeRepos: "8fe7d6755672baecdb938a4c6c407c84be5a5f32507f6cdc7d157d24a043af15",
    .breakdownDraftedThreeRepos: "8cbdcc03f685469d38d5bf64ac8901d63d0b9f2a03427d2d500b761f8f01fee0",
    .verifierReported: "95acf13bc19f3b87b402fbf79a1a00854a55f09ba8ddab44fbf5ce8c440ca5e7",
    .verifierFailed: "a52c4b637f685edb166e1914cb79b9f3cfd2f4ed5a9032fbf31dc181740d1a8d"
]

@Test(
    "Every RehearsalResultFixture's embedded bytes match a pinned SHA-256",
    arguments: RehearsalResultFixture.allCases
)
func everyRehearsalFixtureMatchesPinnedDigest(_ fixture: RehearsalResultFixture) throws {
    let digest = SHA256.hash(data: fixture.data()).map { String(format: "%02x", $0) }.joined()
    let expected = try #require(expectedFixtureDigests[fixture])
    #expect(digest == expected)
}

@Test("workerEmpty is zero bytes and classifies Crashed-Unknown")
func workerEmptyIsZeroBytesAndCrashedUnknown() {
    #expect(RehearsalResultFixture.workerEmpty.data().isEmpty)
    guard case .crashedUnknown = RehearsalResultFixture.workerEmpty.outcome() else {
        Issue.record("expected workerEmpty to classify Crashed-Unknown")
        return
    }
}

@Test("The with-contract selection fixture selects both fixture-backend and fixture-web")
func selectionSelectedWithContractDecodes() throws {
    guard case .selection(let result) = try RehearsalResultFixture.selectionSelectedWithContract.decode(),
        case .selected(let feature) = result.outcome
    else {
        Issue.record("expected selection .selected")
        return
    }
    #expect(feature.repositories == ["fixture-backend", "fixture-web"])
}

@Test("The with-contract breakdown fixture's fixture-web Card carries the fixture-backend contract")
func breakdownDraftedWithContractDecodes() throws {
    guard case .breakdown(let result) = try RehearsalResultFixture.breakdownDraftedWithContract.decode(),
        case .drafted(let breakdown) = result.outcome
    else {
        Issue.record("expected breakdown .drafted")
        return
    }
    #expect(breakdown.cards.count == 2)
    let backendCard = try #require(breakdown.cards.first { $0.repository == "fixture-backend" })
    #expect(backendCard.contracts.isEmpty)
    let webCard = try #require(breakdown.cards.first { $0.repository == "fixture-web" })
    #expect(webCard.contracts.count == 1)
    let contract = try #require(webCard.contracts.first)
    #expect(contract.repository == "fixture-backend")
    #expect(contract.paths == ["contracts/fixture-api.json"])
}

@Test("The adopting selection fixture decodes with empty adopted_card_issue_ids (synthesized by RehearsalDispatch)")
func selectionSelectedAdoptingDecodes() throws {
    guard case .selection(let result) = try RehearsalResultFixture.selectionSelectedAdopting.decode(),
        case .selected(let feature) = result.outcome
    else {
        Issue.record("expected selection .selected")
        return
    }
    #expect(feature.repositories == ["fixture-backend", "fixture-web"])
    #expect(feature.adoptedCardIssueIDs.isEmpty)
}

@Test("The three-repository selection fixture selects fixture-backend, fixture-web and fixture-mobile")
func selectionSelectedThreeReposDecodes() throws {
    guard case .selection(let result) = try RehearsalResultFixture.selectionSelectedThreeRepos.decode(),
        case .selected(let feature) = result.outcome
    else {
        Issue.record("expected selection .selected")
        return
    }
    #expect(feature.repositories == ["fixture-backend", "fixture-web", "fixture-mobile"])
    #expect(feature.adoptedCardIssueIDs.isEmpty)
}

@Test("The three-repository breakdown fixture's Cards are ordered per repository, in file order")
func breakdownDraftedThreeReposDecodes() throws {
    guard case .breakdown(let result) = try RehearsalResultFixture.breakdownDraftedThreeRepos.decode(),
        case .drafted(let breakdown) = result.outcome
    else {
        Issue.record("expected breakdown .drafted")
        return
    }
    #expect(breakdown.definitionOfDone.count == 2)
    #expect(breakdown.cards.count == 5)
    let backendCards = breakdown.cards.filter { $0.repository == "fixture-backend" }
    #expect(backendCards.map(\.title) == [
        "Fixture Card: backend 1 of 3", "Fixture Card: backend 2 of 3", "Fixture Card: backend 3 of 3"
    ])
    #expect(backendCards.allSatisfy { $0.contracts.isEmpty })
    let webCard = try #require(breakdown.cards.first { $0.repository == "fixture-web" })
    #expect(webCard.contracts.count == 1)
    #expect(webCard.contracts.first?.repository == "fixture-backend")
    #expect(webCard.contracts.first?.paths == ["contracts/fixture-api.json"])
    let mobileCard = try #require(breakdown.cards.first { $0.repository == "fixture-mobile" })
    #expect(mobileCard.contracts.isEmpty)
}
