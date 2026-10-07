import Domain
import Foundation
import GRDB
import Testing

@testable import Journal

private struct JournalFixture: ~Copyable {
    let directory: URL
    let projectID: ProjectID

    init(project: String = "fixture") throws {
        directory = FileManager.default.temporaryDirectory
            .appending(component: "yh-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        projectID = try #require(ProjectID(rawValue: project))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: projectID)
    }
}

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

@Test("All JournalEventType raw values match spec names")
func eventTypeRawValues() {
    let expected = [
        "ActStarted", "ActEnded", "ActIdle", "ActIncomplete", "ActStoodDown", "LinearAuthorizationHalted",
        "MainlineFetchFailed", "AbsentNightDetected", "AuthoringNoWorkAvailable",
        "AuthoringSkippedFeatureInFlight", "AuthoringPredecessorNotLanded",
        "AuthoringPredecessorIndeterminate", "PredecessorWalkSkippedReleasedFeature",
        "PredecessorAncestryObserved", "MainlineConflictDetected",
        "ManagedBlockDelimiterBroken", "NotificationDeliveryFailed", "RateBudgetExhausted",
        "LeaseReclaimed", "CardLeaseReclaimed", "NightOpened", "NightClosed", "NightOpenedAndDied",
        "ManagedBlockWritten", "NightCardOpened", "NightCardCompleted", "BoardWriteFailed", "OutboxGroupRolledBack",
        "CardShelved", "CardReopened", "CardRestated", "CardRemovedFromBoard",
        "AuthoringInvariantBroken", "DeltaReadCompleted", "CardStateTransitioned", "WaitingOnYouUnbacked",
        "WorktreeLost", "WorktreeFenced", "WorktreeNotQuiescent", "WorktreeWIPCommitted",
        "WorktreeReconciliationFailed", "RouteExhausted", "OverrideRefused", "RoutePreflightRan",
        "AttemptEnded", "RouteRetried", "BudgetEpochReset",
        "ExpiredCardLeasesSwept", "BoardStateReposted", "RepoLanesDerived", "RepoLaneStarted", "RepoLaneEnded",
        "ReadinessCheckPassed", "ReadinessCheckFailed", "CardDiverged", "TranscriptionStampVoided",
        "ClauseMinted", "ClauseInvalidated", "ClauseDeleted", "ProtectedPathRefused", "CardQuestionAsked",
        "WaitingOnYouReplyRecorded", "WaitingOnYouReplyBanked", "HumanCardComment",
        "CardRunStep", "CheckRan", "AttemptWorkPreserved", "FailureCauseRecorded", "LaneHoleRecorded",
        "CardReclaimed", "CardReclaimDeferred", "AgentCLIProcessSpawned", "RehearsalFixtureAnswered",
        "CardCommitTrailerMissing", "CardCommitTrailersUnread",
        "LeftoverProcessRecorded",
        "FeatureSelected", "FeatureAuthoringHalted", "FeatureAuthoringAccepted", "FeatureAuthored",
        "FeatureAuthoringFailed", "FeatureBreakdownRejected", "AuthoringDispatched", "FeatureSelectionFailed",
        "RefusalOpened", "RefusalRepeated", "RefusalExpired", "RefusalCountReset",
        "LandStep", "CycleLanded", "NoPushedBranchOutcome", "FeatureVerified", "FeatureReturned", "CycleArchived",
        "RefusalAnswered", "AuthoringHaltOpened", "AuthoringHaltRepeated", "AuthoringHaltExpired",
        "AuthoringHaltCleared", "FeatureClosedByMerge", "FeatureSettled", "FeatureReleased",
        "SettleValueNotHonoured", "CardUnansweredBoundFired",
        "AdoptionRefused", "CardAdopted", "AdoptionUntestable",
        "FeatureReselected", "ReselectionBoundReached", "RefusalPromotedToStandingItem", "AppInstallationTokenRefresh",
        "CardPromotedToStandingItem", "ProjectRemoved", "WorktreeNameCollision"
    ]
    let actual = JournalEventType.allCases.map { $0.rawValue }.sorted()
    #expect(actual == expected.sorted())
}

@Test("actStarted event round-trips")
func actStartedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    let id = try journal.append(.actStarted, act: .build, runID: run, now: epoch)
    let records = try journal.events()

    #expect(records.count == 1)
    #expect(records[0].id == id)
    #expect(records[0].event == .actStarted)
    #expect(records[0].act == .build)
    #expect(records[0].runID == run)
    #expect(records[0].nightID == nil)
    #expect(records[0].occurredAt == epoch)
}

@Test("actEnded event round-trips")
func actEndedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    _ = try journal.append(.actEnded, act: .land, runID: run, now: epoch)
    let records = try journal.events()

    #expect(records.count == 1)
    #expect(records[0].event == .actEnded)
}

@Test("linearAuthorizationHalted event round-trips")
func linearAuthorizationHaltedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    _ = try journal.append(.linearAuthorizationHalted, act: .build, runID: run, now: epoch)
    let records = try journal.events()

    #expect(records.count == 1)
    #expect(records[0].event == .linearAuthorizationHalted)
}

@Test("actIncomplete event with reason round-trips")
func actIncompleteRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    let reason = "Something failed"

    _ = try journal.append(.actIncomplete(reason: reason), act: .author, runID: run, now: epoch)
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .actIncomplete(let readReason) = records[0].event else {
        Issue.record("Event is not actIncomplete")
        return
    }
    #expect(readReason == reason)
}

@Test("actStoodDown event with holder round-trips")
func actStoodDownRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let runID = RunID()
    let holderRunID = RunID()
    let holder = ActLease(
        act: .build,
        runID: holderRunID,
        mode: .rehearsal,
        claimedAt: epoch,
        heartbeatAt: epoch,
        expiresAt: epoch.addingTimeInterval(600)
    )

    try journal.append(.actStoodDown(holder: holder), act: .land, runID: runID, now: epoch)
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .actStoodDown(let readHolder) = records[0].event else {
        Issue.record("Event is not actStoodDown")
        return
    }
    #expect(readHolder == holder)
}

@Test("mainlineFetchFailed event round-trips")
func mainlineFetchFailedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    let event = JournalEvent.mainlineFetchFailed(
        repository: "backend", reason: "Network timeout"
    )
    try journal.append(event, act: .build, runID: run, now: epoch)
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .mainlineFetchFailed(let repo, let reason) = records[0].event else {
        Issue.record("Event is not mainlineFetchFailed")
        return
    }
    #expect(repo == "backend")
    #expect(reason == "Network timeout")
}

@Test("absentNightDetected event round-trips")
func absentNightDetectedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    let nightStart = NightStart(rawValue: "2026-01-01")!

    try journal.append(.absentNightDetected(nightStart: nightStart), act: .author, runID: run, now: epoch)
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .absentNightDetected(let readNightStart) = records[0].event else {
        Issue.record("Event is not absentNightDetected")
        return
    }
    #expect(readNightStart == nightStart)
}

@Test("absentNightDetected with unreadable payload throws eventUnreadable")
func absentNightDetectedUnreadablePayload() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()

    #expect(throws: JournalError.eventUnreadable(id: 1)) {
        try journal.write { db in
            let payload = "{\"night_start\": \"not-a-date\"}"
            try db.execute(
                sql: """
                INSERT INTO event (night_id, act, run_id, type, occurred_at, payload)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    nil, nil, nil, JournalEventType.absentNightDetected.rawValue,
                    JournalStore.timestamp(epoch), payload
                ]
            )
        }
        _ = try journal.events()
    }
}

@Test("authoringNoWorkAvailable event round-trips")
func authoringNoWorkAvailableRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(.authoringNoWorkAvailable, act: .author, runID: run, now: epoch)
    let records = try journal.events()

    #expect(records.count == 1)
    #expect(records[0].event == .authoringNoWorkAvailable)
}

// authoringSkippedFeatureInFlight and authoringPredecessorNotLanded (P9.1) round-trip in
// AuthorActEventEncodingTests.swift, split out to keep this file under the file length limit.

@Test("managedBlockDelimiterBroken event round-trips")
func managedBlockDelimiterBrokenRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(.managedBlockDelimiterBroken(issueID: "GH-123"), act: .build, runID: run, now: epoch)
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .managedBlockDelimiterBroken(let issueID) = records[0].event else {
        Issue.record("Event is not managedBlockDelimiterBroken")
        return
    }
    #expect(issueID == "GH-123")
}

@Test("notificationDeliveryFailed event round-trips")
func notificationDeliveryFailedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .notificationDeliveryFailed(notification: "build_complete", reason: "User disabled"),
        act: .build,
        runID: run,
        now: epoch
    )
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .notificationDeliveryFailed(let notif, let reason) = records[0].event else {
        Issue.record("Event is not notificationDeliveryFailed")
        return
    }
    #expect(notif == "build_complete")
    #expect(reason == "User disabled")
}

@Test("worktreeNameCollision event round-trips")
func worktreeNameCollisionRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(
        .worktreeNameCollision(repository: "backend", requested: "rozd/yh-x", reported: "yh-x"),
        act: .build,
        runID: run,
        now: epoch
    )
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .worktreeNameCollision(let repository, let requested, let reported) = records[0].event else {
        Issue.record("Event is not worktreeNameCollision")
        return
    }
    #expect(repository == "backend")
    #expect(requested == "rozd/yh-x")
    #expect(reported == "yh-x")
    #expect(records[0].type == .worktreeNameCollision)
}

@Test("rateBudgetExhausted event contains installation-wide budget and round-trips")
func rateBudgetExhaustedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()

    try journal.append(.rateBudgetExhausted(degradation: "3 fewer cycles"), act: .build, runID: run, now: epoch)

    // Verify payload contains installation-wide budget string
    try journal.read { db in
        let payloadJSON: String? = try String.fetchOne(db, sql: "SELECT payload FROM event LIMIT 1")
        #expect(payloadJSON != nil)
        if let payloadJSON {
            let data = payloadJSON.data(using: .utf8) ?? Data()
            let dict = try JSONDecoder().decode([String: String].self, from: data)
            #expect(dict["budget"] == "installation-wide")
            #expect(dict["degradation"] == "3 fewer cycles")
            #expect(dict["installation"] == nil)
            #expect(dict["workspace"] == nil)
        }
    }

    let records = try journal.events()
    #expect(records.count == 1)
    guard case .rateBudgetExhausted(let degradation, let installation) = records[0].event else {
        Issue.record("Event is not rateBudgetExhausted")
        return
    }
    #expect(degradation == "3 fewer cycles")
    #expect(installation == nil)
}

@Test("rateBudgetExhausted carries its Board Connection's name and workspace when given one")
func rateBudgetExhaustedCarriesInstallation() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let label = AppInstallationLabel(name: "acme", workspace: BoardObjectID(rawValue: "workspace-1"))

    try journal.append(
        .rateBudgetExhausted(degradation: "reads only", installation: label), act: .build, runID: RunID(),
        now: epoch
    )

    let event = try #require(try journal.events().first?.event)
    #expect(event == .rateBudgetExhausted(degradation: "reads only", installation: label))
    #expect(event.payload?["budget"] == "installation-wide")
    #expect(event.payload?["installation"] == "acme")
    #expect(event.payload?["workspace"] == "workspace-1")
}

@Test("leaseReclaimed event round-trips")
func leaseReclaimedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    let previousRun = RunID()
    let expiredAt = epoch.addingTimeInterval(600)

    try journal.append(
        .leaseReclaimed(previousRunID: previousRun, previousAct: .build, expiredAt: expiredAt),
        act: .author,
        runID: run,
        now: epoch
    )
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .leaseReclaimed(let readRunID, let readAct, let readExpiredAt) = records[0].event else {
        Issue.record("Event is not leaseReclaimed")
        return
    }
    #expect(readRunID == previousRun)
    #expect(readAct == .build)
    #expect(readExpiredAt == expiredAt)
}

@Test("cardLeaseReclaimed event round-trips")
func cardLeaseReclaimedRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    let previousRun = RunID()
    let cardID: Int64 = 42
    let expiredAt = epoch.addingTimeInterval(600)

    try journal.append(
        .cardLeaseReclaimed(cardID: cardID, previousRunID: previousRun, expiredAt: expiredAt),
        act: nil,
        runID: run,
        now: epoch
    )
    let records = try journal.events()

    #expect(records.count == 1)
    guard case .cardLeaseReclaimed(let readCardID, let readRunID, let readExpiredAt) = records[0].event else {
        Issue.record("Event is not cardLeaseReclaimed")
        return
    }
    #expect(readCardID == cardID)
    #expect(readRunID == previousRun)
    #expect(readExpiredAt == expiredAt)
}

@Test("appInstallationTokenRefresh events round-trip, refreshed and refused, and carry no token keys")
func appInstallationTokenRefreshRoundTrips() throws {
    let fixture = try JournalFixture()
    let journal = try fixture.open()
    let run = RunID()
    let previous = epoch.addingTimeInterval(60)
    let label = AppInstallationLabel(name: "acme", workspace: BoardObjectID(rawValue: "workspace-1"))
    let refreshed = AppInstallationTokenRefresh(
        installation: label, attemptedAt: epoch, trigger: .nearExpiry, previousExpiresAt: previous,
        outcome: .refreshed(expiresAt: epoch.addingTimeInterval(7200))
    )
    let refused = AppInstallationTokenRefresh(
        installation: label, attemptedAt: epoch, trigger: .accessTokenRejected, previousExpiresAt: previous,
        outcome: .refused(.init(status: 401, code: "invalid_client", description: "No", message: "m"))
    )
    let transport = AppInstallationTokenRefresh(
        installation: label, attemptedAt: epoch, trigger: .nearExpiry, previousExpiresAt: previous,
        outcome: .unreachable(message: "unreachable")
    )
    let notStored = AppInstallationTokenRefresh(
        installation: label, attemptedAt: epoch, trigger: .nearExpiry, previousExpiresAt: previous,
        outcome: .notStored(message: "could not store")
    )

    for refresh in [refreshed, refused, transport, notStored] {
        try journal.append(.appInstallationTokenRefresh(refresh), act: .build, runID: run, now: epoch)
    }
    let records = try journal.events()

    #expect(records.map(\.event) == [refreshed, refused, transport, notStored].map { .appInstallationTokenRefresh($0) })
    #expect(records.allSatisfy { $0.type == .appInstallationTokenRefresh })
    #expect([refreshed, refused, transport, notStored].map {
        JournalEvent.appInstallationTokenRefresh($0).payload?["outcome"]
    } == ["refreshed", "refused", "unreachable", "not-stored"])
    #expect(JournalEvent.appInstallationTokenRefresh(refused).payload?.keys.sorted() == [
        "attempted_at", "code", "description", "installation", "message", "outcome", "previous_expires_at", "status",
        "trigger", "workspace"
    ])
    #expect(JournalEvent.appInstallationTokenRefresh(refreshed).payload?["installation"] == "acme")
    #expect(JournalEvent.appInstallationTokenRefresh(refreshed).payload?["workspace"] == "workspace-1")
    for case .appInstallationTokenRefresh(let decoded) in records.map(\.event) {
        #expect(decoded.installation == label)
    }
}
