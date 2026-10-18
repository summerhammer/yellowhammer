import Domain
import Foundation
import Testing

@testable import Journal
@testable import Pulse

private struct AuthoringFixture: ~Copyable {
    let directory = FileManager.default.temporaryDirectory.appending(component: "yh-authoring-pulse-\(UUID())")
    deinit { try? FileManager.default.removeItem(at: directory) }

    func open() throws -> JournalStore {
        try JournalStore.open(configurationDirectory: directory, projectID: #require(ProjectID(rawValue: "fixture")))
    }
}

private func openAuthoringNight(_ journal: JournalStore) throws -> Int64 {
    let run = RunID()
    _ = try journal.claimActLease(act: .author, runID: run, mode: .real, now: epoch)
    return try journal.openNight(nightStart: nightStart, mode: .real, act: .author, runID: run, now: epoch).night.id
}

@Test("Authoring decisions show without a Feature or Cycle, with the stored title, reason and Linear UUID link")
func authoringDecisionsWithoutCycle() throws {
    let fixture = AuthoringFixture()
    let journal = try fixture.open()
    let nightID = try openAuthoringNight(journal)
    let haltName = try #require(FeatureName(rawValue: "Contract seam"))
    let refusalName = try #require(FeatureName(rawValue: "Thin specification"))
    let issueID = "6f0c2b1e-3a52-4d6a-9d1c-0a7a4b9f1e11"
    try journal.recordAuthoringHalt(
        feature: haltName, causeKind: "no-backward-compatible-seam", content: "No compatible seam found",
        nightID: nightID, now: epoch
    )
    try journal.recordAuthoringHaltIssue(feature: haltName, issueID: issueID)
    try journal.recordRefusal(feature: refusalName, content: "Supply citable clauses", nightID: nightID, now: epoch)

    let pulse = try PulseSnapshot.read(from: journal, status: .idle, asOf: epoch)
    #expect(pulse.feature == nil)
    #expect(pulse.night?.verdictLine?.contains("Authoring Feature “Contract seam” halted") == true)
    #expect(pulse.night?.verdictLine?.contains("Authoring Feature “Thin specification” refused") == true)
    #expect(pulse.needsYou.count == 2)
    #expect(pulse.needsYou.waitingOnYouCount == 2)
    #expect(!pulse.needsYou.isEmpty)
    let halt = try #require(pulse.needsYou.authoringDecisions.first { $0.kind == .halt })
    #expect(halt.title == "Contract seam")
    #expect(halt.reason == "No compatible seam found")
    #expect(halt.link?.url.absoluteString == "https://linear.app/issue/" + issueID)
    #expect(pulse.needsYou.authoringDecisions.last?.link == nil)
    #expect(pulse.night?.cardsAbsence.contains("awaiting an Operator turn") == true)
    #expect(pulse.health == nil)
}

@Test("Cleared halts, answered Refusals and cleanly re-authored Refusals leave Needs you")
func authoringDecisionLifecycle() throws {
    let fixture = AuthoringFixture()
    let journal = try fixture.open()
    let nightID = try openAuthoringNight(journal)
    let name = try #require(FeatureName(rawValue: "Sync"))
    try journal.recordAuthoringHalt(feature: name, causeKind: "unknown", content: "A reason", nightID: nightID)
    try journal.recordRefusal(feature: name, content: "Thin specification", nightID: nightID)
    #expect(try PulseSnapshot.read(from: journal, status: .idle).needsYou.count == 2)
    try journal.clearAuthoringHalts(feature: name, nightID: nightID)
    try journal.answerRefusal(feature: name, citation: "spec#clause", nightID: nightID)
    #expect(try PulseSnapshot.read(from: journal, status: .idle).needsYou.isEmpty)
    try journal.recordRefusal(feature: name, content: "Another finding", nightID: nightID)
    #expect(try PulseSnapshot.read(from: journal, status: .idle).needsYou.count == 1)
    try journal.resetConsecutiveRefusals(feature: name, nightID: nightID)
    #expect(try journal.refusals(feature: name).last?.state == .open)
    #expect(try journal.refusals(feature: name).last?.closedNightID == nightID)
    let pulse = try PulseSnapshot.read(from: journal, status: .idle)
    #expect(pulse.needsYou.waitingOnYouCount == 0)
    #expect(pulse.needsYou.isEmpty)
    #expect(pulse.night?.cardsAbsence.contains("awaiting an Operator turn") == false)
}

@Test("Recorded Feature links take precedence and malformed stop IDs never become URLs")
func authoringDecisionLinkMetadata() throws {
    let fixture = AuthoringFixture()
    let journal = try fixture.open()
    let nightID = try openAuthoringNight(journal)
    let name = try #require(FeatureName(rawValue: "Sync"))
    let other = try #require(FeatureName(rawValue: "Other"))
    let seeded = try insertFeature(journal, issueID: "feature-id")
    try journal.write { db in
        try db.execute(
            sql: """
                UPDATE feature SET issue_key = 'YH-572', issue_url = 'https://linear.app/team/issue/YH-572'
                WHERE id = ?
                """,
            arguments: [seeded.featureID]
        )
    }
    try journal.recordAuthoringHalt(feature: name, causeKind: "unknown", content: "Reason", nightID: nightID)
    try journal.recordAuthoringHaltIssue(feature: name, issueID: "feature-id")
    try journal.recordRefusal(feature: other, content: "Thin", nightID: nightID)
    try journal.recordRefusalIssue(feature: other, issueID: "javascript:alert(1)")
    let decisions = try PulseSnapshot.read(from: journal, status: .idle).needsYou.authoringDecisions
    #expect(decisions.first?.link?.identifier == "YH-572")
    #expect(decisions.first?.link?.url.absoluteString == "https://linear.app/team/issue/YH-572")
    #expect(decisions.last?.link == nil)
}

@Test("Halt and Refusal account events are actionable problems without failed Act logs")
func authoringDecisionAccountProblems() {
    let events: [JournalEvent] = [
        .featureAuthoringHalted(name: "Sync", reasonKind: "unknown", detail: nil),
        .authoringHaltOpened(feature: "Sync", causeKind: "unknown", detail: nil),
        .authoringHaltRepeated(feature: "Sync", causeKind: "unknown", detail: nil),
        .refusalOpened(feature: "Sync", consecutiveRefusals: 1, uncitableClauses: "", reselectionDepth: 0),
        .refusalRepeated(feature: "Sync", consecutiveRefusals: 2, uncitableClauses: "", reselectionDepth: 0)
    ]
    for event in events {
        let record = JournalEventRecord(id: 1, event: event, act: .author, runID: nil, nightID: 1, occurredAt: epoch)
        let entry = NightAccount.Entry(record: record, cardNames: [:])
        #expect(entry.isProblem)
        #expect(entry.failedAct == nil)
        #expect(entry.headline.contains("halted") || entry.headline.contains("refused"))
    }
}

@Test("An open authoring decision remains visible when a later Night opens")
func authoringDecisionCarriesToLaterNight() throws {
    let fixture = AuthoringFixture()
    let journal = try fixture.open()
    let nightID = try openAuthoringNight(journal)
    let name = try #require(FeatureName(rawValue: "Sync"))
    let issueID = "6f0c2b1e-3a52-4d6a-9d1c-0a7a4b9f1e11"
    try journal.recordRefusal(feature: name, content: "Needs clauses", nightID: nightID)
    try journal.recordRefusalIssue(feature: name, issueID: issueID)
    let run = try #require(try journal.currentActLease()).runID
    _ = try journal.closeNight(id: nightID, reason: .nightEnd, act: .author, runID: run, now: epoch)
    _ = try journal.openNight(
        nightStart: #require(NightStart(rawValue: "2026-09-30")), mode: .real, act: .author,
        runID: run, now: epoch
    )
    let pulse = try PulseSnapshot.read(from: journal, status: .idle)
    #expect(pulse.needsYou.count == 1)
    #expect(pulse.needsYou.authoringDecisions.first?.link?.url.absoluteString == "https://linear.app/issue/" + issueID)
    #expect(pulse.night?.verdictLine?.contains("Authoring Feature “Sync” refused — awaiting an Operator turn") == true)
}
