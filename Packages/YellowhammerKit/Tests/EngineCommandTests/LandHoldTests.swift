import Domain
@testable import Engine
import Foundation
@testable import Journal
import Testing

private final class LandHoldFixture {
    let directory: URL
    let journal: JournalStore
    let runID = RunID()
    let night: NightRecord
    let cycleID: Int64
    let cardID: Int64
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    init(reason: BlockReason? = nil, waiting: WaitingReason = .question) throws {
        directory = FileManager.default.temporaryDirectory.appending(component: "yh-hold-\(UUID())")
        journal = try JournalStore.openSeeded(configurationDirectory: directory,
                                             projectID: #require(ProjectID(rawValue: "hold")))
        _ = try journal.claimActLease(act: .build, runID: runID, mode: .real,
                                      policy: LeasePolicy(heartbeatInterval: 60, timeToLive: 86_400), now: start)
        night = try journal.openNight(nightStart: #require(NightStart(rawValue: "2026-10-28")),
                                      mode: .real, act: .build, runID: runID, now: start).night
        let start = self.start
        let ids: (Int64, Int64) = try journal.write { db in
            try db.execute(sql: "INSERT INTO feature(issue_id,state,created_at) VALUES ('F','selected',?)",
                           arguments: [JournalStore.timestamp(start)])
            try db.execute(sql: "INSERT INTO cycle(feature_id,created_at) VALUES (?,?)",
                           arguments: [db.lastInsertedRowID, JournalStore.timestamp(start)])
            let cycle = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO card(
                    cycle_id,issue_id,repository,kind,authored_order,state,waiting_reason,block_reason,created_at
                )
                VALUES (?,'C','main','card',1,?,?,?,?)
                """, arguments: [cycle, reason == nil ? CardState.waitingOnYou.rawValue : CardState.blocked.rawValue,
                                  reason == nil ? waiting.rawValue : nil, reason?.rawValue,
                                  JournalStore.timestamp(start)])
            return (cycle, db.lastInsertedRowID)
        }
        cycleID = ids.0
        cardID = ids.1
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func evaluate(
        _ act: Act, minute: Int, wait: Int = 30, forced: Bool = false, nightStart: Date? = nil
    ) throws -> ActTriggerOutcome {
        let now = start.addingTimeInterval(Double(minute) * 60)
        _ = try journal.heartbeatActLease(runID: runID,
                                          policy: LeasePolicy(heartbeatInterval: 60, timeToLive: 86_400), now: now)
        return try ActTriggerPredicate.evaluate(
            act: act, trigger: forced ? .forced : .scheduled, journal: journal, nightID: night.id, runID: runID,
            landHoldSchedule: LandHoldSchedule(start: nightStart ?? start, end: start.addingTimeInterval(8 * 3_600),
                                               buildEveryMinutes: 15, answerWaitMinutes: wait), now: now
        )
    }

    func read(at minute: Int, complete: Bool = true) throws {
        let event: JournalEvent = complete
            ? .deltaReadCompleted(objects: 0, comments: 0, ownComments: 0, requests: 1, since: nil, syncPoint: nil)
            : .deltaReadIncomplete(requests: 40, reason: "cap")
        try journal.append(event, act: .build, runID: runID, nightID: night.id,
                           now: start.addingTimeInterval(Double(minute) * 60))
    }
}

@Test("Questions keep land idle, build met, and expire only at land after a completed build read")
func questionLandHold() throws {
    let fixture = try LandHoldFixture()
    #expect(try fixture.evaluate(.land, minute: 1) == .notMet(.waitingForAnswer))
    #expect(try fixture.evaluate(.build, minute: 31) == .met)
    #expect(try fixture.evaluate(.land, minute: 31) == .notMet(.waitingForAnswer))
    try fixture.read(at: 32, complete: false)
    #expect(try fixture.evaluate(.land, minute: 33) == .notMet(.waitingForAnswer))
    try fixture.read(at: 34)
    #expect(try fixture.evaluate(.build, minute: 40) == .met)
    #expect(try fixture.evaluate(.land, minute: 45) == .met)
    #expect(try fixture.evaluate(.build, minute: 46) == .notMet(.cycleHasNoUnfinishedCards))
}

@Test("One-minute Bound still spans a build read on a fifteen-minute grid")
func shortLandHold() throws {
    let fixture = try LandHoldFixture()
    #expect(try fixture.evaluate(.land, minute: 15, wait: 1) == .notMet(.waitingForAnswer))
    let span = try fixture.journal.activeLandHold(cycleID: fixture.cycleID)
    #expect(span?.endsAt == fixture.start.addingTimeInterval(1_800))
    try fixture.read(at: 16)
    #expect(try fixture.evaluate(.land, minute: 30, wait: 1) == .met)
}

@Test("Only the four ruled Block Reasons hold landing", arguments: BlockReason.allCases)
func blockedLandHold(reason: BlockReason) throws {
    let fixture = try LandHoldFixture(reason: reason)
    let holds = [BlockReason.checkFailure, .routeFailure, .hostCrash, .engineFault].contains(reason)
    #expect(try fixture.evaluate(.land, minute: 1) == (holds ? .notMet(.waitingForAnswer) : .met))
}

@Test("Divergence and overreach never hold landing", arguments: [WaitingReason.divergence, .overreach])
func otherWaitingDoesNotHold(reason: WaitingReason) throws {
    let fixture = try LandHoldFixture(waiting: reason)
    #expect(try fixture.evaluate(.land, minute: 1) == .met)
}

@Test("Forced land bypasses the hold and records why it ended")
func forcedLandEndsHold() throws {
    let fixture = try LandHoldFixture()
    _ = try fixture.evaluate(.land, minute: 1)
    #expect(try fixture.evaluate(.land, minute: 2, forced: true) == .met)
    #expect(try fixture.journal.landHolds(nightID: fixture.night.id).first?.endReason == "forced land")
}

@Test("A push attempt prevents all later holds and makes scheduled build idle")
func handoffPreventsHold() throws {
    let fixture = try LandHoldFixture()
    _ = try fixture.evaluate(.land, minute: 1)
    try fixture.journal.beginCycleHandoff(cycleID: fixture.cycleID, runID: fixture.runID,
                                         now: fixture.start.addingTimeInterval(60))
    #expect(try fixture.evaluate(.land, minute: 2) == .met)
    #expect(try fixture.evaluate(.build, minute: 3) == .notMet(.handoffBegun))
}

@Test("The hold-ending firing ignores the Bound and the missing build read")
func closingFiringEndsHold() throws {
    let fixture = try LandHoldFixture()
    _ = try fixture.evaluate(.land, minute: 1)
    #expect(try fixture.evaluate(.land, minute: 480) == .met)
    #expect(try fixture.journal.hasNightHoldEnded(nightID: fixture.night.id))
}

@Test("An answer observed by another Act during the hold resumes at build")
func heldAnswerFromAnotherAct() async throws {
    let fixture = try LandHoldFixture()
    _ = try fixture.evaluate(.land, minute: 1)
    let draft = CardReplyDraft(cardID: fixture.cardID, issueID: "C", questionID: nil,
                               commentID: "answer", body: "yes", authorName: nil, disposition: .answer,
                               commentedAt: fixture.start.addingTimeInterval(60))
    _ = try fixture.journal.recordCardReply(draft, nightID: fixture.night.id, act: .author,
                                           runID: fixture.runID, now: fixture.start.addingTimeInterval(60))
    let context = ActContext(act: .build, mode: .real, trigger: .scheduled, runID: fixture.runID,
                             journal: fixture.journal, night: fixture.night)
    try await WaitingOnYouReplies.apply(context: context, unansweredNightsMax: 3)
    #expect(try fixture.journal.card(id: fixture.cardID).state == .todo)
    #expect(try fixture.journal.unappliedCardReplies().isEmpty)
}

@Test("An answer after a failed push is banked while the Cycle remains unlanded")
func answerAfterHandoffBanked() async throws {
    let fixture = try LandHoldFixture()
    try fixture.journal.beginCycleHandoff(cycleID: fixture.cycleID, runID: fixture.runID, now: fixture.start)
    let draft = CardReplyDraft(cardID: fixture.cardID, issueID: "C", questionID: nil,
                               commentID: "answer", body: "yes", authorName: nil, disposition: .answer,
                               commentedAt: fixture.start)
    _ = try fixture.journal.recordCardReply(draft, nightID: fixture.night.id, act: .author,
                                           runID: fixture.runID, now: fixture.start)
    let context = ActContext(act: .author, mode: .real, trigger: .scheduled, runID: fixture.runID,
                             journal: fixture.journal, night: fixture.night)
    try await WaitingOnYouReplies.apply(context: context, unansweredNightsMax: 3)
    #expect(try fixture.journal.card(id: fixture.cardID).state == .waitingOnYou)
    #expect(try fixture.journal.bankedCardReplies(cardID: fixture.cardID).count == 1)
}

@Test("A new Night restarts the hold and requires a fresh build read")
func holdRestartsEachNight() throws {
    let fixture = try LandHoldFixture()
    _ = try fixture.evaluate(.land, minute: 1)
    try fixture.read(at: 16)
    #expect(try fixture.evaluate(.land, minute: 30) == .met)
    let secondStart = fixture.start.addingTimeInterval(86_400)
    _ = try fixture.journal.claimActLease(
        act: .land, runID: fixture.runID, mode: .real,
        policy: LeasePolicy(heartbeatInterval: 60, timeToLive: 86_400), now: secondStart
    )
    let secondIdentity = try #require(NightStart(rawValue: "2026-10-29"))
    let night = try fixture.journal.openNight(nightStart: secondIdentity,
                                              mode: .real, act: .land, runID: fixture.runID, now: secondStart).night
    let outcome = try ActTriggerPredicate.evaluate(
        act: .land, trigger: .scheduled, journal: fixture.journal, nightID: night.id, runID: fixture.runID,
        landHoldSchedule: LandHoldSchedule(start: secondStart, end: secondStart.addingTimeInterval(28_800)),
        now: secondStart.addingTimeInterval(1_900)
    )
    #expect(outcome == .notMet(.waitingForAnswer))
    #expect(try fixture.journal.activeLandHold(cycleID: fixture.cycleID)?.startedAt == secondStart)
}

@Test("First flush after a missed closing land runs land work before closing the Night")
func flushEndsHoldBeforeClosing() async throws {
    let fixture = try LandHoldFixture()
    _ = try fixture.journal.releaseActLease(runID: fixture.runID)
    var invocation = EngineInvocation(
        act: .land, mode: .real, nightStart: fixture.night.nightStart, journal: fixture.journal,
        closesNight: true, work: { context in
            #expect(try context.journal.night(id: context.night.id)?.isOpen == true)
            try context.journal.append(.actIdle(reason: .waitingForAnswer), act: .land,
                                       runID: context.runID, nightID: context.night.id)
        }
    )
    invocation.isFlushFiring = true
    invocation.landHoldSchedule = LandHoldSchedule(start: Date().addingTimeInterval(-28_800),
                                                   end: Date().addingTimeInterval(-900))
    try await invocation.run()
    let idle = try fixture.journal.events(ofType: .actIdle)
    #expect(idle.count == 1)
    #expect(try fixture.journal.night(id: fixture.night.id)?.isOpen == false)
    // No earlier firing recorded the span: closing reconstructs it from durable Card state.
    let spans = try fixture.journal.landHolds(nightID: fixture.night.id)
    #expect(spans.count == 1)
    #expect(spans.first?.endReason == "hold-ending firing")
}

@Test("Flush after a closing land has fired only closes, without another landing opportunity")
func flushAfterClosingFiredDoesNotLand() async throws {
    let fixture = try LandHoldFixture()
    try fixture.journal.endNightHold(nightID: fixture.night.id, runID: fixture.runID, now: fixture.start)
    _ = try fixture.journal.releaseActLease(runID: fixture.runID)
    var invocation = EngineInvocation(
        act: .land, mode: .real, nightStart: fixture.night.nightStart, journal: fixture.journal,
        closesNight: true, work: { _ in Issue.record("A closing land already ended this hold") }
    )
    invocation.isFlushFiring = true
    try await invocation.run()
    #expect(try fixture.journal.night(id: fixture.night.id)?.isOpen == false)
}
