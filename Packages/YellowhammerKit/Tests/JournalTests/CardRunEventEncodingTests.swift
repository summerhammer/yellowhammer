import Domain
import Foundation
import Testing

@testable import Journal

// The Card run's event (roadmap P8.4) round-trips here, split out of EventEncodingTests.swift to keep
// that file under the length limit.

@Test("cardRunStep event round-trips for every step, with and without a detail")
func cardRunStepRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-journal-cardrun-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try JournalStore.open(
        configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "fixture"))
    )
    let run = RunID()
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    for (index, step) in CardRunStep.allCases.enumerated() {
        let detail: String? = index.isMultiple(of: 2) ? "detail \(step.rawValue)" : nil
        try journal.append(
            .cardRunStep(cardID: 7, issueID: "BACK-1", step: step, detail: detail),
            act: .build, runID: run, now: epoch
        )
    }
    let records = try journal.events(ofType: .cardRunStep)

    #expect(records.count == CardRunStep.allCases.count)
    for (index, step) in CardRunStep.allCases.enumerated() {
        let detail: String? = index.isMultiple(of: 2) ? "detail \(step.rawValue)" : nil
        #expect(records[index].event == .cardRunStep(cardID: 7, issueID: "BACK-1", step: step, detail: detail))
    }
}

@Test("checkRan event round-trips for every result, with and without a status and output")
func checkRanRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-journal-checkran-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try JournalStore.open(
        configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "fixture"))
    )
    let run = RunID()
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    let events: [JournalEvent] = [
        .checkRan(
            cardID: 7, issueID: "BACK-1", attemptID: 3, result: .passed, exitStatus: 0, output: "ok\n",
            judgedCommit: "b763aff"
        ),
        .checkRan(
            cardID: 7, issueID: "BACK-1", attemptID: 3, result: .failed, exitStatus: 127, output: "line\n\"quoted\"\n",
            judgedCommit: nil
        ),
        .checkRan(
            cardID: 7, issueID: "BACK-1", attemptID: 3, result: .declaredNone, exitStatus: nil, output: nil,
            judgedCommit: "fddeef4"
        )
    ]

    for event in events {
        try journal.append(event, act: .build, runID: run, now: epoch)
    }
    let records = try journal.events(ofType: .checkRan)

    #expect(records.map(\.event) == events)
    #expect(Set(events.compactMap { event -> CheckRunResult? in
        if case .checkRan(_, _, _, let result, _, _, _) = event { result } else { nil }
    }) == Set(CheckRunResult.allCases))
}

@Test("A checkRan payload written before judged_commit existed decodes with a nil judgedCommit")
func checkRanWithoutJudgedCommitDecodes() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-journal-checkran-legacy-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try JournalStore.open(
        configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "fixture"))
    )
    try journal.write { db in
        try db.execute(
            sql: """
            INSERT INTO event (night_id, act, run_id, type, occurred_at, payload)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                nil, nil, nil, JournalEventType.checkRan.rawValue,
                JournalStore.timestamp(Date(timeIntervalSince1970: 1_800_000_000)),
                "{\"card_id\": \"7\", \"issue_id\": \"BACK-1\", \"attempt_id\": \"3\", \"result\": \"passed\", "
                    + "\"exit_status\": \"0\"}"
            ]
        )
    }

    let records = try journal.events(ofType: .checkRan)

    #expect(records.map(\.event) == [
        .checkRan(
            cardID: 7, issueID: "BACK-1", attemptID: 3, result: .passed, exitStatus: 0, output: nil,
            judgedCommit: nil
        )
    ])
}

@Test("failureCauseRecorded event round-trips")
func failureCauseRecordedRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-journal-failurecause-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try JournalStore.open(
        configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "fixture"))
    )
    let event = JournalEvent.failureCauseRecorded(
        cardID: 7, issueID: "BACK-1", cause: "hard failure (exit status 2)", causeHash: "abc123",
        recurrenceCount: 2
    )

    try journal.append(event, act: .build, runID: RunID(), now: Date(timeIntervalSince1970: 1_800_000_000))

    #expect(try journal.events(ofType: .failureCauseRecorded).map(\.event) == [event])
}

@Test("leftoverProcessRecorded event round-trips for every disposition, with and without a cwd")
func leftoverProcessRecordedRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(component: "yh-journal-leftover-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = try JournalStore.open(
        configurationDirectory: directory, projectID: try #require(ProjectID(rawValue: "fixture"))
    )
    let run = RunID()
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    let events: [JournalEvent] = [
        .leftoverProcessRecorded(
            cardID: 7, issueID: "BACK-1", attemptID: 3, pass: .worker, pid: 4242, commandName: "node",
            disposition: .sweptByRunningSnapshot, cwd: nil
        ),
        .leftoverProcessRecorded(
            cardID: 7, issueID: "BACK-1", attemptID: 3, pass: .worker, pid: 4343, commandName: "python3",
            disposition: .sweptByWorktreeFence, cwd: nil
        ),
        .leftoverProcessRecorded(
            cardID: 7, issueID: "BACK-1", attemptID: 3, pass: .worker, pid: 4444, commandName: "sleep",
            disposition: .leftRunningUnattributed, cwd: "/tmp/yh-wt-backend"
        )
    ]

    for event in events {
        try journal.append(event, act: .build, runID: run, now: epoch)
    }
    let records = try journal.events(ofType: .leftoverProcessRecorded)

    #expect(records.map(\.event) == events)
    #expect(Set(events.compactMap { event -> LeftoverProcessDisposition? in
        if case .leftoverProcessRecorded(_, _, _, _, _, _, let disposition, _) = event { disposition } else { nil }
    }) == Set(LeftoverProcessDisposition.allCases))
}
