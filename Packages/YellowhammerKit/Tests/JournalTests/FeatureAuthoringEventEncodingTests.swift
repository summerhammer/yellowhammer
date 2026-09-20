import Domain
import Foundation
import Testing

@testable import Journal

// roadmap P9.4: the authoring transaction's three events round-trip through the event log, and the plan
// is appended in the same Journal transaction that accepts the Outbox group.

private struct AuthoringJournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-authoring-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: "fixture"))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private let plan = FeatureAuthoringAcceptedPayload(
    name: "FEAT-1", groupKey: "authoring:FEAT-1:0", featureKey: "feature:FEAT-1:0:create", nightID: 7,
    cards: [
        PlannedCard(
            key: "card:FEAT-1:0:backend:2:create", repository: "backend", kind: "impl.a", order: 2,
            title: "One, \"two\""
        ),
        PlannedCard(key: "card:FEAT-1:0:mobile:1:create", repository: "mobile", kind: "*", order: 1, title: "Mobile")
    ],
    adoptions: [PlannedAdoption(key: "adopt:FEAT-1:0:CARD-1", cardIssueID: "CARD-1", repository: "backend", order: 1)]
)

@Test("featureAuthoringAccepted round-trips its whole plan")
func featureAuthoringAcceptedRoundTrips() throws {
    let fixture = try AuthoringJournalFixture()
    let journal = try fixture.open()

    try journal.append(.featureAuthoringAccepted(plan), act: .author, runID: RunID(), now: epoch)
    let records = try journal.events()

    #expect(records.count == 1)
    #expect(records[0].type == .featureAuthoringAccepted)
    #expect(JournalEventType.featureAuthoringAccepted.rawValue == "FeatureAuthoringAccepted")
    guard case .featureAuthoringAccepted(let read) = records[0].event else {
        Issue.record("Event is not featureAuthoringAccepted")
        return
    }
    #expect(read == plan)
}

@Test("featureAuthoringAccepted round-trips clauses and uncitable clauses (roadmap P9.5)")
func featureAuthoringAcceptedRoundTripsClauses() throws {
    let fixture = try AuthoringJournalFixture()
    let journal = try fixture.open()
    let withClauses = FeatureAuthoringAcceptedPayload(
        name: "FEAT-1", groupKey: "authoring:FEAT-1:0", featureKey: "feature:FEAT-1:0:create", nightID: 7,
        cards: [
            PlannedCard(
                key: "card:FEAT-1:0:backend:1:create", repository: "backend", kind: "impl.a", order: 1,
                title: "One", clauses: [PlannedClause(cid: "c1", text: "Card clause", citation: "epic/story")]
            )
        ],
        adoptions: [],
        featureClauses: [PlannedClause(cid: "c1", text: "Feature clause", citation: "epic/story")],
        uncitableClauses: [
            PlannedUncitableClause(
                level: "card", cardTitle: "One", text: "Dropped", citation: "epic/ghost",
                reason: "the citation could not be resolved"
            )
        ]
    )

    try journal.append(.featureAuthoringAccepted(withClauses), act: .author, runID: RunID(), now: epoch)
    guard case .featureAuthoringAccepted(let read) = try journal.events()[0].event else {
        Issue.record("Event is not featureAuthoringAccepted")
        return
    }
    #expect(read == withClauses)
}

@Test("A legacy featureAuthoringAccepted payload with no clause keys decodes with empty clause lists")
func featureAuthoringAcceptedDecodesLegacyPayloadWithoutClauses() throws {
    // A P9.4-era payload never wrote "feature_clauses" or "uncitable_clauses" keys at all: decoding the
    // event directly (bypassing `append`, which would always write the current, clause-carrying shape)
    // is how this simulates a row an earlier build of the engine actually wrote.
    let legacyCards = [
        PlannedCard(
            key: "card:FEAT-1:0:backend:1:create", repository: "backend", kind: "impl.a", order: 1, title: "One"
        )
    ]
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let legacyRow: [String: String] = [
        "name": "FEAT-1", "group_key": "authoring:FEAT-1:0", "feature_key": "feature:FEAT-1:0:create",
        "night_id": "7",
        "cards": String(data: try encoder.encode(legacyCards), encoding: .utf8) ?? "[]",
        "adoptions": "[]"
    ]

    let event = try JournalEvent(type: .featureAuthoringAccepted, payload: legacyRow, rowID: 1)

    guard case .featureAuthoringAccepted(let read) = event else {
        Issue.record("Event is not featureAuthoringAccepted")
        return
    }
    #expect(read.featureClauses.isEmpty)
    #expect(read.uncitableClauses.isEmpty)
    #expect(read.cards == legacyCards)
}

@Test("featureAuthoringAccepted round-trips an empty plan")
func featureAuthoringAcceptedRoundTripsEmptyLists() throws {
    let fixture = try AuthoringJournalFixture()
    let journal = try fixture.open()
    let empty = FeatureAuthoringAcceptedPayload(
        name: "F", groupKey: "g", featureKey: "k", nightID: 1, cards: [], adoptions: []
    )

    try journal.append(.featureAuthoringAccepted(empty), act: .author, runID: RunID(), now: epoch)

    guard case .featureAuthoringAccepted(let read) = try journal.events()[0].event else {
        Issue.record("Event is not featureAuthoringAccepted")
        return
    }
    #expect(read == empty)
}

@Test("featureAuthored round-trips")
func featureAuthoredRoundTrips() throws {
    let fixture = try AuthoringJournalFixture()
    let journal = try fixture.open()
    let payload = FeatureAuthoredPayload(
        name: "FEAT-1", groupKey: "authoring:FEAT-1:0", featureIssueID: "issue-9", cycleID: 3, cardCount: 4,
        adoptedCount: 1
    )

    try journal.append(.featureAuthored(payload), act: .author, runID: RunID(), now: epoch)

    let record = try journal.events()[0]
    #expect(record.type == .featureAuthored)
    #expect(JournalEventType.featureAuthored.rawValue == "FeatureAuthored")
    guard case .featureAuthored(let read) = record.event else {
        Issue.record("Event is not featureAuthored")
        return
    }
    #expect(read == payload)
}

@Test("featureAuthoringFailed round-trips")
func featureAuthoringFailedRoundTrips() throws {
    let fixture = try AuthoringJournalFixture()
    let journal = try fixture.open()

    try journal.append(
        .featureAuthoringFailed(name: "FEAT-1", groupKey: "authoring:FEAT-1:0", reason: "Linear said no, twice"),
        act: .author, runID: RunID(), now: epoch
    )

    let record = try journal.events()[0]
    #expect(record.type == .featureAuthoringFailed)
    #expect(JournalEventType.featureAuthoringFailed.rawValue == "FeatureAuthoringFailed")
    guard case .featureAuthoringFailed(let name, let groupKey, let reason) = record.event else {
        Issue.record("Event is not featureAuthoringFailed")
        return
    }
    #expect(name == "FEAT-1" && groupKey == "authoring:FEAT-1:0" && reason == "Linear said no, twice")
}

@Test("acceptOutbox appends the plan's event once, in the same transaction as the group")
func acceptOutboxAppendsEventAtomically() throws {
    let fixture = try AuthoringJournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    guard case .claimed = try journal.claimActLease(act: .author, runID: run, mode: .rehearsal, now: epoch) else {
        Issue.record("could not claim the Act Lease")
        return
    }
    let draft = OutboxDraft(clientID: UUID(), operation: "issueCreate", payload: "{}", groupID: plan.groupKey)

    let event = JournalEvent.featureAuthoringAccepted(plan)
    _ = try journal.acceptOutbox([draft], runID: run, now: epoch, appending: event, act: .author)
    // Replaying the same acceptance inserts nothing, so it must not append the event a second time.
    _ = try journal.acceptOutbox([draft], runID: run, now: epoch, appending: event, act: .author)

    #expect(try journal.events(ofType: .featureAuthoringAccepted).count == 1)
    #expect(try journal.outboxEntries(groupID: plan.groupKey).count == 1)
    #expect(try journal.unfinishedAuthoringPlan() == plan)
}

@Test("acceptOutbox under a lost Act Lease appends no event")
func acceptOutboxWithoutLeaseAppendsNothing() throws {
    let fixture = try AuthoringJournalFixture()
    let journal = try fixture.open()
    let draft = OutboxDraft(clientID: UUID(), operation: "issueCreate", payload: "{}", groupID: plan.groupKey)

    #expect(throws: JournalError.self) {
        try journal.acceptOutbox([draft], runID: RunID(), now: epoch, appending: .featureAuthoringAccepted(plan))
    }
    #expect(try journal.events().isEmpty)
}
