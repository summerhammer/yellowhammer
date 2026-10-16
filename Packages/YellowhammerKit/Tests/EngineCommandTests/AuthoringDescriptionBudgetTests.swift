import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

// feature-authoring/author-the-cycle-and-features-work-cards, "description limit": every description the
// transaction composes is measured against the Board Connection's description budget before anything is
// accepted into the Outbox — a Work Card at its largest maintained rendering — and a Work Card over it walks
// the authoring Routes. The content of a breakdown is model-authored and never asserted: only sizes, Routes
// and what reached the board.

private let first = Route(cli: "claude", model: "opus", effort: "high")!
private let second = Route(cli: "codex", model: "gpt-5.4", effort: "high")!

private func budget(_ value: Int, unit: DescriptionLengthUnit = .utf16CodeUnits) throws -> DescriptionBudget {
    try DescriptionBudget(configured: value, limit: BoardDescriptionLimit(maximum: 250_000, unit: unit))
}

/// One backend Card whose brief is `brief`.
private func breakdown(title: String, brief: String) throws -> FeatureBreakdown {
    FeatureBreakdown(
        definitionOfDone: [authoringClause("The Feature is done.")],
        cards: [CardDraft(
            repository: "backend", kind: try authoringKind(), title: title, unitOfWork: "Do \(title)", brief: brief,
            definitionOfDone: [authoringClause("\(title) is done.")]
        )]
    )
}

private func rig(
    _ breakdowns: [FeatureBreakdown], routes: [Route] = [first, second], budget: DescriptionBudget?
) async throws -> AuthoringRig {
    let rig = try await AuthoringRig(drafting: ScriptedBreakdown(routes: routes, breakdowns: breakdowns))
    rig.descriptionBudget = budget
    return rig
}

private func rejectedReason(_ journal: JournalStore) throws -> String {
    let rejected = try #require(try journal.events(ofType: .featureBreakdownRejected).first)
    guard case .featureBreakdownRejected(_, let reason) = rejected.event else {
        Issue.record("expected featureBreakdownRejected")
        return ""
    }
    return reason
}

/// The size a Work Card is measured at, read back from the fault a too-small budget produces.
private func measuredSize(of breakdown: FeatureBreakdown, tooSmall: Int = 2_000) async throws -> Int {
    let probe = try await rig([breakdown], routes: [first], budget: try budget(tooSmall))
    #expect(try await probe.run(probe.context()) == .authoringRolledBack)
    let reason = try rejectedReason(probe.journal)
    let digits = try #require(reason.split(separator: " ").drop { $0 != "composes" }.dropFirst().first)
    return try #require(Int(digits.replacingOccurrences(of: ",", with: "")))
}

private let spendingKind = "impl.boilerplate"
private let spendingUnit = "Build it"
private let spendingClauses = ["First clause.", "A second, longer clause."]
private let spendingCitation = "resolvable/story"

/// One backend Card whose brief is `briefLength` characters, with two clauses and the given contracts.
private func spendingBreakdown(briefLength: Int, contracts: [ContractDraft] = []) throws -> FeatureBreakdown {
    FeatureBreakdown(
        definitionOfDone: [authoringClause("The Feature is done.")],
        cards: [CardDraft(
            repository: "backend", kind: try authoringKind(spendingKind), title: "Spender",
            unitOfWork: spendingUnit, brief: String(repeating: "x", count: briefLength),
            definitionOfDone: spendingClauses.map(authoringClause), contracts: contracts
        )]
    )
}

/// What the prompt's arithmetic says a Card spends outside its brief: the kind, the unit of work, each
/// clause's overhead and text and citation, and each contract's overhead, paths and twice what it names.
private func spendingOutsideTheBrief(_ room: BreakdownDescriptionRoom, contracts: [ContractDraft]) -> Int {
    let clauses = spendingClauses.reduce(0) {
        $0 + room.clauseOverhead + $1.utf16.count + spendingCitation.utf16.count
    }
    let references = contracts.reduce(0) { total, contract in
        let named = contract.repository.utf16.count + contract.paths.reduce(0) { $0 + $1.utf16.count }
        return total + room.referenceOverhead + room.pathOverhead * contract.paths.count + 2 * named
    }
    return spendingKind.utf16.count + spendingUnit.utf16.count + clauses + references
}

@Suite("Authoring: the description budget")
struct AuthoringDescriptionBudgetTests {
    private let big = String(repeating: "Approach. ", count: 400)

    @Test("A Work Card over the budget walks the Routes; with none left the fault names the last breakdown's card")
    func everyRouteOverBudget() async throws {
        let rig = try await rig(
            [try breakdown(title: "First draft", brief: big), try breakdown(title: "Second draft", brief: big)],
            budget: try budget(2_000)
        )

        let outcome = try await rig.run(rig.context())

        #expect(outcome == .authoringRolledBack)
        #expect(rig.drafting.callCount == 1)
        #expect(rig.drafting.dispatchedRoutes == [first, second])
        let reason = try rejectedReason(rig.journal)
        #expect(reason.contains("Work Card \"Second draft\" (backend)"))
        #expect(!reason.contains("First draft"))
        #expect(reason.contains("UTF-16 code units"))
        #expect(reason.contains("over the description budget of 2,000"))
        #expect(reason.contains("Architectural Brief"))
        #expect(reason.contains("no Route left for the authoring Kind"))
        #expect(!reason.hasSuffix("."))
        #expect(try tableRowCount(rig.journal, table: "outbox") == 0)
        #expect(await rig.boards.writing.liveIssues.isEmpty)
        #expect(await rig.boards.writing.createIssueCalls == 0)
    }

    @Test("Over budget on one Route and within it on the next: authored on the second Route")
    func secondRouteFits() async throws {
        let rig = try await rig(
            [try breakdown(title: "Too long", brief: big), try breakdown(title: "Short", brief: "Approach.")],
            budget: try budget(2_000)
        )

        let outcome = try await rig.run(rig.context())

        #expect(outcome == .authored)
        #expect(rig.drafting.dispatchedRoutes == [first, second])
        #expect(try rig.journal.events(ofType: .featureBreakdownRejected).isEmpty)
        #expect(try cardRows(rig.journal).map(\.title) == ["Short"])
    }

    @Test("A Work Card with no Route behind it is a fault at once")
    func noRouteIsAFault() async throws {
        let rig = try await rig([try breakdown(title: "Too long", brief: big)], routes: [], budget: try budget(2_000))

        #expect(try await rig.run(rig.context()) == .authoringRolledBack)
        #expect(rig.drafting.callCount == 1)
        #expect(try rejectedReason(rig.journal).contains("Work Card \"Too long\""))
        #expect(try tableRowCount(rig.journal, table: "outbox") == 0)
    }

    @Test("A Feature Card over the budget is rejected after one drafting, with no Route walk")
    func featureCardOverBudget() async throws {
        let seam = String(repeating: "seam ", count: 800)
        let sequence = FeatureSequence(precededBy: "none", followedBy: "none", seam: seam)
        let rig = try await AuthoringRig(
            sequence: sequence,
            drafting: ScriptedBreakdown(
                routes: [first, second], breakdowns: [try breakdown(title: "Small", brief: "Approach.")]
            )
        )
        rig.descriptionBudget = try budget(3_000)

        #expect(try await rig.run(rig.context()) == .authoringRolledBack)

        #expect(rig.drafting.callCount == 1)
        #expect(rig.drafting.dispatchedRoutes == [first])
        let reason = try rejectedReason(rig.journal)
        #expect(reason.contains("Feature Card \"FEAT-1\""))
        #expect(reason.contains("Sequence"))
        #expect(reason.contains("the roll-up"))
        #expect(!reason.hasSuffix("."))
        #expect(try tableRowCount(rig.journal, table: "outbox") == 0)
        #expect(await rig.boards.writing.liveIssues.isEmpty)
    }

    @Test("A Work Card exactly at its largest maintained size is authored; one unit less is not")
    func boundary() async throws {
        let card = try breakdown(title: "Boundary", brief: big)
        let size = try await measuredSize(of: card)

        let fits = try await rig([card], routes: [first], budget: try budget(size))
        #expect(try await fits.run(fits.context()) == .authored)

        let over = try await rig([card], routes: [first], budget: try budget(size - 1))
        #expect(try await over.run(over.context()) == .authoringRolledBack)
        #expect(try tableRowCount(over.journal, table: "outbox") == 0)
    }

    @Test("The room for Attempts is reserved: the measured size is above what the create description needs")
    func reservesRoomForAttempts() async throws {
        let card = try breakdown(title: "Reserve", brief: big)
        let size = try await measuredSize(of: card)
        let unreserved = ManagedBlockFence.initialDescription(rendered: "### Architectural Brief\n\(big)").utf16.count
        let reserve = CardManagedBlock.widestCompactedAttemptsSection(longestRoute: second).utf16.count
        #expect(size > unreserved + reserve)
    }

    @Test("An emoji brief is counted in UTF-16 code units: it fits by Character count and is rejected")
    func emojiCountsInUTF16() async throws {
        let parrots = String(repeating: "🦜", count: 600)
        let card = try breakdown(title: "Parrots", brief: parrots)
        let size = try await measuredSize(of: card, tooSmall: 1_000)
        // 600 emoji are 600 Characters and 1,200 code units: the budget sits between the two sizes.
        let between = size - 300

        let utf16 = try await rig([card], routes: [first], budget: try budget(between))
        #expect(try await utf16.run(utf16.context()) == .authoringRolledBack)
        #expect(try rejectedReason(utf16.journal).contains("UTF-16 code units"))

        let characters = try await rig([card], routes: [first], budget: try budget(between, unit: .characters))
        #expect(try await characters.run(characters.context()) == .authored)
    }

    @Test("With no budget nothing is measured: a huge brief is authored")
    func noBudget() async throws {
        let huge = try breakdown(title: "Huge", brief: String(repeating: "x", count: 60_000))
        let rig = try await rig([huge], budget: nil)

        #expect(try await rig.run(rig.context()) == .authored)
        #expect(rig.drafting.callCount == 1)
    }

    @Test("A Work Card that spends exactly the room it is told is authored; one unit more is not")
    func spendingTheRoomExactly() async throws {
        let limit = try budget(10_000)
        let room = AuthoringDescriptionBudget(budget: limit, longestRoute: first).room(repositories: ["backend"])
        let briefLength = try #require(room.rooms.first).room - spendingOutsideTheBrief(room, contracts: [])

        let fits = try await rig([try spendingBreakdown(briefLength: briefLength)], routes: [first], budget: limit)
        #expect(try await fits.run(fits.context()) == .authored)
        #expect(try cardRows(fits.journal).map(\.title) == ["Spender"])

        let over = try await rig([try spendingBreakdown(briefLength: briefLength + 1)], routes: [first], budget: limit)
        #expect(try await over.run(over.context()) == .authoringRolledBack)
        #expect(try rejectedReason(over.journal).contains("Work Card \"Spender\" (backend) composes 10,001"))
        #expect(try tableRowCount(over.journal, table: "outbox") == 0)
    }

    @Test("The room covers a contract reference: its measured size is within a few units of the told arithmetic")
    func contractReferenceIsInTheRoom() async throws {
        let limit = try budget(10_000)
        let room = AuthoringDescriptionBudget(budget: limit, longestRoute: first).room(repositories: ["backend"])
        let contracts = [ContractDraft(repository: "backend", paths: ["api.json"])]
        let briefLength = try #require(room.rooms.first).room - spendingOutsideTheBrief(room, contracts: contracts)

        let size = try await measuredSize(
            of: try spendingBreakdown(briefLength: briefLength, contracts: contracts), tooSmall: 2_000
        )

        // A Card spending the told arithmetic to the unit is never measured over the budget, and at most one
        // unit under: `pathOverhead` rounds up (the first path has no separator before it). The fake
        // transcriber stamps the Project's mainline commit, which the arithmetic assumes is a 40-character sha.
        #expect(size <= 10_000)
        #expect(10_000 - size <= 1)
    }

    @Test("A rejection names every section the Work Card is measured in")
    func rejectionNamesEverySection() async throws {
        let contracts = [ContractDraft(repository: "backend", paths: ["api.json"])]
        let rig = try await rig(
            [try spendingBreakdown(briefLength: 3_000, contracts: contracts)], routes: [first],
            budget: try budget(2_000)
        )

        #expect(try await rig.run(rig.context()) == .authoringRolledBack)

        let reason = try rejectedReason(rig.journal)
        for section in WorkCardDescriptionSection.allCases {
            #expect(reason.contains(section.title), "\(section.title)")
        }
    }
}
